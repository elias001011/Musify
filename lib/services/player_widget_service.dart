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

import 'package:audio_service/audio_service.dart';
import 'package:home_widget/home_widget.dart';
import 'package:musify/services/audio_service.dart';
import 'package:musify/services/logger_service.dart';

/// Keeps the Android home-screen player widget in sync with the audio session.
///
/// Widget actions are handled by Android's media controller, so the play action
/// intentionally reaches [MusifyAudioHandler.play]. That method already owns
/// Musify's queue/last-song resumption behaviour.
class PlayerWidgetService {
  PlayerWidgetService._();

  static const androidProviderName = 'PlayerWidgetProvider';
  static const qualifiedAndroidProviderName =
      'com.gokadzev.musify.PlayerWidgetProvider';

  static const titleKey = 'player_widget_title';
  static const artistKey = 'player_widget_artist';
  static const artworkKey = 'player_widget_artwork';
  static const playingKey = 'player_widget_is_playing';
  static const loadingKey = 'player_widget_is_loading';
  static const hasMediaKey = 'player_widget_has_media';
  static const canSkipPreviousKey = 'player_widget_can_skip_previous';
  static const canSkipNextKey = 'player_widget_can_skip_next';

  static final PlayerWidgetService instance = PlayerWidgetService._();

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _debounce;
  MusifyAudioHandler? _handler;
  String? _lastFingerprint;

  void start(MusifyAudioHandler handler) {
    if (!Platform.isAndroid || identical(_handler, handler)) return;

    stop();
    _handler = handler;
    _subscriptions
      ..add(handler.mediaItem.listen((_) => _scheduleSync()))
      ..add(handler.playbackState.listen((_) => _scheduleSync()))
      ..add(handler.queue.listen((_) => _scheduleSync()))
      ..add(HomeWidget.widgetClicked.listen(_handleLaunchAction));
    unawaited(
      HomeWidget.initiallyLaunchedFromHomeWidget().then(_handleLaunchAction),
    );
    _scheduleSync(immediate: true);
  }

  Future<void> _handleLaunchAction(Uri? uri) async {
    if (uri?.scheme != 'musify-widget') return;

    final handler = _handler;
    if (handler == null) return;
    switch (uri?.host) {
      case 'play':
        await handler.play();
        break;
      case 'previous':
        await handler.skipToPrevious();
        break;
      case 'next':
        await handler.skipToNext();
        break;
    }
  }

  void stop() {
    _debounce?.cancel();
    _debounce = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handler = null;
    _lastFingerprint = null;
  }

  void _scheduleSync({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      unawaited(_sync());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    final handler = _handler;
    if (handler == null) return;

    final item = handler.mediaItem.value;
    final resumableSong = item == null ? handler.latestResumableSong : null;
    final state = handler.playbackState.value;
    final currentQueue = handler.queue.value;
    final queueIndex = state.queueIndex ?? 0;
    final title =
        item?.title.trim() ?? resumableSong?['title']?.toString() ?? '';
    final artist =
        item?.artist?.trim() ??
        resumableSong?['artist']?.toString().trim() ??
        '';
    final artwork =
        item?.artUri?.toString() ?? _resumableArtwork(resumableSong) ?? '';
    final isLoading =
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;
    final hasMedia = item != null || resumableSong != null;
    final canSkipPrevious = currentQueue.length > 1 && queueIndex > 0;
    final canSkipNext =
        currentQueue.length > 1 && queueIndex < currentQueue.length - 1;

    final fingerprint = [
      title,
      artist,
      artwork,
      state.playing,
      isLoading,
      hasMedia,
      canSkipPrevious,
      canSkipNext,
    ].join('|');
    if (_lastFingerprint == fingerprint) return;

    try {
      await Future.wait([
        HomeWidget.saveWidgetData<String>(titleKey, title),
        HomeWidget.saveWidgetData<String>(artistKey, artist),
        HomeWidget.saveWidgetData<String>(artworkKey, artwork),
        HomeWidget.saveWidgetData<bool>(playingKey, state.playing),
        HomeWidget.saveWidgetData<bool>(loadingKey, isLoading),
        HomeWidget.saveWidgetData<bool>(hasMediaKey, hasMedia),
        HomeWidget.saveWidgetData<bool>(canSkipPreviousKey, canSkipPrevious),
        HomeWidget.saveWidgetData<bool>(canSkipNextKey, canSkipNext),
      ]);
      await HomeWidget.updateWidget(
        androidName: androidProviderName,
        qualifiedAndroidName: qualifiedAndroidProviderName,
      );
      _lastFingerprint = fingerprint;
    } catch (error, stackTrace) {
      Logger().log(
        'Unable to update player widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _resumableArtwork(Map? song) {
    if (song == null) return null;
    final artworkPath = song['artworkPath']?.toString();
    if (artworkPath != null && artworkPath.isNotEmpty) {
      return Uri.file(artworkPath).toString();
    }
    for (final key in ['highResImage', 'lowResImage', 'image']) {
      final value = song[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}
