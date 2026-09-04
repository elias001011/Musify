import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist_alarm.dart';

void main() {
  const oneTimeAlarm = PlaylistAlarm(
    id: 'alarm-1',
    hour: 7,
    minute: 30,
    playlistId: 'playlist-1',
    playlistTitle: 'Morning mix',
    enabled: true,
  );

  test('one-time alarm uses today when its time is still ahead', () {
    final next = oneTimeAlarm.nextOccurrence(from: DateTime(2026, 9, 4, 6));
    expect(next, DateTime(2026, 9, 4, 7, 30));
  });

  test('one-time alarm rolls to tomorrow after its time passed', () {
    final next = oneTimeAlarm.nextOccurrence(from: DateTime(2026, 9, 4, 8));
    expect(next, DateTime(2026, 9, 5, 7, 30));
  });

  test('repeating alarm selects the next enabled weekday', () {
    final alarm = oneTimeAlarm.copyWith(
      weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
    );
    final next = alarm.nextOccurrence(
      from: DateTime(2026, 9, 4, 8), // Friday, after the alarm time.
    );
    expect(next, DateTime(2026, 9, 7, 7, 30));
  });

  test('stored alarm round-trips and drops invalid weekdays', () {
    final restored = PlaylistAlarm.fromMap({
      ...oneTimeAlarm.toMap(),
      'weekdays': [1, 3, 8, -1],
    });
    expect(restored, isNotNull);
    expect(restored!.weekdays, {1, 3});
    expect(restored.playlistTitle, 'Morning mix');
  });
}
