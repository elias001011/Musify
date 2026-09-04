/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:musify/main.dart' show logger;
import 'package:musify/models/playlist_alarm.dart';
import 'package:musify/services/audio_service.dart';
import 'package:musify/services/playlist_download_service.dart';
import 'package:musify/services/playlists_manager.dart';
import 'package:musify/services/settings_manager.dart';

class PlaylistAlarmService {
  PlaylistAlarmService._() {
    alarms = ValueNotifier<List<PlaylistAlarm>>(_readAlarms());
  }

  static final PlaylistAlarmService instance = PlaylistAlarmService._();
  static const _storageKey = 'playlistAlarms';
  static const _channel = MethodChannel('com.gokadzev.musify/playlist_alarm');

  late final ValueNotifier<List<PlaylistAlarm>> alarms;
  MusifyAudioHandler? _audioHandler;
  bool _initialized = false;
  final Map<String, DateTime> _recentFirings = {};

  Future<void> initialize(MusifyAudioHandler handler) async {
    _audioHandler = handler;
    if (!Platform.isAndroid || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'alarmFired') {
        await _handleAlarmFired(call.arguments?.toString());
      }
    });

    try {
      await syncNativeSchedule();
      final initialAlarmId = await _channel.invokeMethod<String>(
        'getInitialAlarmId',
      );
      if (initialAlarmId != null) {
        unawaited(_handleAlarmFired(initialAlarmId));
      }
    } catch (error, stackTrace) {
      logger.log(
        'Unable to initialize playlist alarms',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  List<PlaylistAlarm> _readAlarms() {
    final stored = Hive.box('settings')
        .get(_storageKey, defaultValue: const <dynamic>[]);
    if (stored is! List) return [];
    return stored
        .map(PlaylistAlarm.fromMap)
        .whereType<PlaylistAlarm>()
        .toList();
  }

  Future<void> save(PlaylistAlarm alarm) async {
    final updated = List<PlaylistAlarm>.from(alarms.value);
    final index = updated.indexWhere((item) => item.id == alarm.id);
    if (index == -1) {
      updated.add(alarm);
    } else {
      updated[index] = alarm;
    }
    updated.sort((a, b) {
      final hourComparison = a.hour.compareTo(b.hour);
      return hourComparison != 0
          ? hourComparison
          : a.minute.compareTo(b.minute);
    });
    await _persist(updated);
  }

  Future<void> remove(String id) async {
    await _persist(alarms.value.where((alarm) => alarm.id != id).toList());
  }

  Future<void> setEnabled(PlaylistAlarm alarm, bool enabled) async {
    await save(alarm.copyWith(enabled: enabled));
  }

  Future<void> _persist(List<PlaylistAlarm> updated) async {
    alarms.value = List.unmodifiable(updated);
    await Hive.box('settings')
        .put(_storageKey, updated.map((alarm) => alarm.toMap()).toList());
    await syncNativeSchedule();
  }

  Future<bool> canScheduleExactAlarms() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? false;
  }

  Future<void> requestExactAlarmPermission() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestExactAlarmPermission');
  }

  Future<bool> syncNativeSchedule() async {
    if (!Platform.isAndroid) return false;
    final enabledAlarms = alarms.value
        .where((alarm) => alarm.enabled)
        .map((alarm) => alarm.toMap())
        .toList();
    return await _channel.invokeMethod<bool>('syncAlarms', {
          'alarms': enabledAlarms,
        }) ??
        false;
  }

  Future<List<Map<String, dynamic>>> availablePlaylists() async {
    final candidates = <dynamic>[
      ...userCustomPlaylists.value,
      for (final folder in userPlaylistFolders.value)
        ...(folder['playlists'] as List? ?? const <dynamic>[]),
      ...getLikedPlaylistItems(),
      ...offlinePlaylistService.offlinePlaylists.value,
      if (!offlineMode.value) ...await getUserPlaylists(),
    ];
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final candidate in candidates) {
      if (candidate is! Map || isArtistPlaylist(candidate)) continue;
      final id = candidate['ytid']?.toString();
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      result.add(Map<String, dynamic>.from(candidate));
    }
    result.sort(
      (a, b) => (a['title']?.toString() ?? '').toLowerCase().compareTo(
        (b['title']?.toString() ?? '').toLowerCase(),
      ),
    );
    return result;
  }

  Future<void> _handleAlarmFired(String? id) async {
    if (id == null || id.isEmpty) return;
    final lastFiring = _recentFirings[id];
    final now = DateTime.now();
    if (lastFiring != null && now.difference(lastFiring).inSeconds < 30) return;
    _recentFirings[id] = now;

    final alarm = alarms.value.cast<PlaylistAlarm?>().firstWhere(
      (item) => item?.id == id,
      orElse: () => null,
    );
    if (alarm == null || !alarm.enabled) return;

    if (!alarm.repeats) {
      await save(alarm.copyWith(enabled: false));
    } else {
      await syncNativeSchedule();
    }

    try {
      final playlist = await getPlaylistInfoForWidget(
        alarm.playlistId,
        forceRefresh: !offlineMode.value,
      );
      final rawSongs = playlist?['list'];
      if (rawSongs is! List) {
        logger.log('Playlist alarm ${alarm.id} has no playable songs');
        return;
      }
      final songs = rawSongs.whereType<Map>().toList();
      if (songs.isEmpty) {
        logger.log('Playlist alarm ${alarm.id} resolved to an empty playlist');
        return;
      }
      await _audioHandler?.addPlaylistToQueue(
        songs,
        replace: true,
        startIndex: 0,
      );
    } catch (error, stackTrace) {
      logger.log(
        'Unable to start playlist alarm ${alarm.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
