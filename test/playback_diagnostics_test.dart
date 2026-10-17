import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musify/services/playback_diagnostics.dart';

void main() {
  test(
    'logs HTTP status without signed URLs or authentication headers',
    () async {
      final logs = <String>[];
      final client = PlaybackDiagnosticClient(
        logs.add,
        inner: MockClient((request) async => http.Response('blocked', 429)),
      );
      addTearDown(client.close);
      final response = await client.get(
        Uri.parse('https://www.youtube.com/watch?v=secret&sig=private'),
        headers: {'cookie': 'private-cookie'},
      );

      expect(response.statusCode, 429);
      expect(response.body, 'blocked');
      expect(logs, ['YouTube HTTP GET www.youtube.com: 429']);
    },
  );

  test(
    'source probe uses a bounded range and matching playback headers',
    () async {
      final logs = <String>[];
      final client = MockClient((request) async {
        expect(request.headers['range'], 'bytes=0-1023');
        expect(request.headers['user-agent'], 'resolving-client');
        return http.Response('', 403);
      });

      await diagnosePlaybackSource(
        'video-id',
        'https://rr1.googlevideo.com/videoplayback?sig=private',
        {'user-agent': 'resolving-client'},
        logs.add,
        client: client,
      );

      expect(logs.single, contains('HTTP 403'));
      expect(logs.single, isNot(contains('private')));
    },
  );

  test('source probe does not request local files or unrelated URLs', () async {
    final logs = <String>[];
    final client = MockClient(
      (_) async => throw StateError('unexpected request'),
    );
    addTearDown(client.close);
    await diagnosePlaybackSource(
      'video-id',
      'file:///music/song.m4a',
      {},
      logs.add,
      client: client,
    );
    expect(logs, isEmpty);
  });
}
