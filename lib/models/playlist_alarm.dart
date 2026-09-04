/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 */

class PlaylistAlarm {
  const PlaylistAlarm({
    required this.id,
    required this.hour,
    required this.minute,
    required this.playlistId,
    required this.playlistTitle,
    required this.enabled,
    this.weekdays = const <int>{},
  });

  final String id;
  final int hour;
  final int minute;
  final String playlistId;
  final String playlistTitle;
  final bool enabled;

  /// ISO weekday numbers (`DateTime.monday` through `DateTime.sunday`).
  /// An empty set means the alarm should fire only once.
  final Set<int> weekdays;

  bool get repeats => weekdays.isNotEmpty;

  DateTime nextOccurrence({DateTime? from}) {
    final now = from ?? DateTime.now();
    var candidate = DateTime(now.year, now.month, now.day, hour, minute);

    if (!repeats) {
      if (!candidate.isAfter(now))
        candidate = candidate.add(const Duration(days: 1));
      return candidate;
    }

    for (var dayOffset = 0; dayOffset <= 7; dayOffset++) {
      final occurrence = candidate.add(Duration(days: dayOffset));
      if (weekdays.contains(occurrence.weekday) && occurrence.isAfter(now)) {
        return occurrence;
      }
    }

    // A valid repeating alarm always finds a day above. Keep a safe fallback
    // for malformed restored data instead of scheduling an alarm immediately.
    return candidate.add(const Duration(days: 1));
  }

  PlaylistAlarm copyWith({
    int? hour,
    int? minute,
    String? playlistId,
    String? playlistTitle,
    bool? enabled,
    Set<int>? weekdays,
  }) {
    return PlaylistAlarm(
      id: id,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      playlistId: playlistId ?? this.playlistId,
      playlistTitle: playlistTitle ?? this.playlistTitle,
      enabled: enabled ?? this.enabled,
      weekdays: weekdays ?? this.weekdays,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'hour': hour,
    'minute': minute,
    'playlistId': playlistId,
    'playlistTitle': playlistTitle,
    'enabled': enabled,
    'weekdays': weekdays.toList()..sort(),
  };

  static PlaylistAlarm? fromMap(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString();
    final playlistId = value['playlistId']?.toString();
    final hour = value['hour'];
    final minute = value['minute'];
    if (id == null ||
        id.isEmpty ||
        playlistId == null ||
        playlistId.isEmpty ||
        hour is! num ||
        minute is! num) {
      return null;
    }

    final parsedHour = hour.toInt();
    final parsedMinute = minute.toInt();
    if (parsedHour < 0 ||
        parsedHour > 23 ||
        parsedMinute < 0 ||
        parsedMinute > 59) {
      return null;
    }

    final weekdays = (value['weekdays'] as List? ?? const <dynamic>[])
        .whereType<num>()
        .map((day) => day.toInt())
        .where((day) => day >= DateTime.monday && day <= DateTime.sunday)
        .toSet();

    return PlaylistAlarm(
      id: id,
      hour: parsedHour,
      minute: parsedMinute,
      playlistId: playlistId,
      playlistTitle: value['playlistTitle']?.toString() ?? '',
      enabled: value['enabled'] == true,
      weekdays: weekdays,
    );
  }
}
