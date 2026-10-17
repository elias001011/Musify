import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musify/constants/clients.dart';
import 'package:musify/services/playback_diagnostics.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

  group('log redaction', () {
    test('redactUrls keeps only scheme and host', () {
      const text =
          'Request failed: GET https://rr1.googlevideo.com/videoplayback?'
          'sig=SECRET&pot=TOKEN (retrying http://127.0.0.1:8080/x?y=1)';
      final redacted = redactUrls(text);
      expect(redacted, contains('https://rr1.googlevideo.com/...'));
      expect(redacted, contains('http://127.0.0.1/...'));
      expect(redacted, isNot(contains('SECRET')));
      expect(redacted, isNot(contains('TOKEN')));
    });

    test('describeStreamUrl exposes only allow-listed parameters', () {
      final description = describeStreamUrl(
        'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140&'
        'mime=audio%2Fmp4&c=VISIONOS&clen=3000&sig=SECRET&lsig=SECRET2&'
        'pot=TOKEN&n=NN&ip=1.2.3.4&expire=1100',
        now: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );
      expect(description, contains('rr1---sn-abc.googlevideo.com'));
      expect(description, contains('itag=140'));
      expect(description, contains('mime=audio/mp4'));
      expect(description, contains('c=VISIONOS'));
      expect(description, contains('expiresIn=100s'));
      expect(description, contains('boundToIp=IPv4'));
      for (final secret in ['SECRET', 'TOKEN', 'NN', '1.2.3.4']) {
        expect(description, isNot(contains(secret)));
      }
    });

    test('describeStreamUrl hides signed paths of manifest URLs', () {
      final description = describeStreamUrl(
        'https://manifest.googlevideo.com/api/manifest/hls_playlist/'
        'expire/1/sig/SIGINPATH/file/index.m3u8',
      );
      expect(description, contains('manifest.googlevideo.com'));
      expect(description, isNot(contains('SIGINPATH')));
    });

    test('describeStreamUrl hides the path of non-googlevideo hosts', () {
      final description = describeStreamUrl(
        'https://example.com/private/token123/stream.m3u8?x=1',
      );
      expect(description, contains('example.com'));
      expect(description, isNot(contains('token123')));
    });
  });

  group('source description', () {
    test('flags header sources as going through the loopback proxy', () {
      final source = AudioSource.uri(
        Uri.parse('https://rr1.googlevideo.com/videoplayback?itag=140&sig=S'),
        headers: {'user-agent': 'client-ua', 'cookie': 'private-cookie'},
      );
      final description = describeAudioSource(source);
      expect(description, contains('ProgressiveAudioSource'));
      expect(description, contains('viaJustAudioLoopbackProxy=true'));
      expect(description, contains('userAgent=client-ua'));
      expect(description, contains('cookie'));
      expect(description, isNot(contains('private-cookie')));
      expect(description, isNot(contains('sig=S')));
    });

    test('a source without headers does not use the proxy', () {
      final description = describeAudioSource(
        AudioSource.uri(Uri.parse('https://rr1.googlevideo.com/videoplayback')),
      );
      expect(description, contains('viaJustAudioLoopbackProxy=false'));
    });

    test('describePlayerError reports code, message and index', () {
      final description = describePlayerError(
        PlayerException(0, 'Source error', 0),
      );
      expect(description, contains('code=0'));
      expect(description, contains('Source error'));
    });
  });

  group('user-agent probe', () {
    test(
      'requests the URL with the client, Dart and ExoPlayer agents',
      () async {
        final logs = <String>[];
        final seen = <String?>[];
        final client = MockClient((request) async {
          seen.add(request.headers['user-agent']);
          expect(request.headers['range'], 'bytes=0-1023');
          return http.Response(
            '',
            request.headers['user-agent'] == 'dart-agent' ? 403 : 206,
          );
        });

        await diagnoseUserAgentVariants(
          'video-id',
          'https://rr1.googlevideo.com/videoplayback?sig=private',
          {'user-agent': 'client-agent'},
          logs.add,
          client: client,
          dartUserAgent: 'dart-agent',
        );

        expect(seen.first, 'client-agent');
        expect(seen[1], 'dart-agent');
        expect(seen, hasLength(3));
        expect(
          logs.single,
          allOf(
            contains('client=206'),
            contains('dart=403'),
            contains('exoplayer=206'),
            isNot(contains('private')),
          ),
        );
      },
    );

    test('ignores URLs that are not on googlevideo', () async {
      final logs = <String>[];
      await diagnoseUserAgentVariants(
        'video-id',
        'https://example.com/a',
        {},
        logs.add,
        client: MockClient((_) async => throw StateError('unexpected')),
      );
      expect(logs, isEmpty);
    });
  });

  group('manifest fallback logging', () {
    test(
      'reports why every client failed, without URL query strings',
      () async {
        final logs = <String>[];
        final errors = <Object?>[];
        final yt = YoutubeExplode(
          httpClient: YoutubeHttpClient(
            MockClient((_) async => http.Response('nope', 500)),
          ),
        );
        addTearDown(yt.close);

        await expectLater(
          getManifestWithFallback(
            yt,
            'dQw4w9WgXcQ',
            timeout: const Duration(seconds: 5),
            log: (message, {error, stackTrace}) {
              logs.add(message);
              errors.add(error);
              expect(stackTrace, isNotNull);
            },
          ),
          throwsA(anything),
        );

        expect(logs, hasLength(fallbackClients.length));
        expect(logs.first, contains('VISIONOS'));
        expect(logs.last, contains('ANDROID'));
        expect(logs.every((l) => l.contains('dQw4w9WgXcQ')), isTrue);
        expect(errors.every((e) => e is String && e.isNotEmpty), isTrue);
      },
    );
  });

  group('loopback cleartext probe', () {
    test('reports a player that never reaches the loopback server', () async {
      final logs = <String>[];
      await diagnoseLoopbackCleartext(
        logs.add,
        loadUrl: (_) async => throw PlayerException(0, 'Source error', 0),
      );
      expect(logs.single, contains('serverRequests=0'));
      expect(logs.single, contains('code=0'));
      expect(logs.single, contains('likely blocked'));
    });

    test('reports a player that did reach the loopback server', () async {
      final logs = <String>[];
      await diagnoseLoopbackCleartext(
        logs.add,
        loadUrl: (url) async {
          final client = HttpClient();
          try {
            final response = await (await client.getUrl(Uri.parse(url)))
                .close();
            await response.drain<void>();
          } finally {
            client.close();
          }
        },
      );
      expect(logs.single, contains('serverRequests=1'));
      expect(logs.single, contains('player loaded it'));
      expect(logs.single, contains('lets ExoPlayer reach'));
    });
  });

  group('native player probe', () {
    test('compares the player without and with the playback headers', () async {
      final logs = <String>[];
      final calls = <Map<String, String>?>[];
      await diagnoseNativePlayback(
        'video-id',
        'https://rr1.googlevideo.com/videoplayback?sig=private',
        {'user-agent': 'client-agent'},
        logs.add,
        load: (url, headers) async {
          calls.add(headers);
          if (headers == null) {
            throw PlayerException(0, 'Source error', 0);
          }
        },
      );

      expect(calls, [
        null,
        {'user-agent': 'client-agent'},
      ]);
      expect(
        logs.single,
        allOf(
          contains('direct=failed (PlayerException code=0'),
          contains('viaProxy=ok'),
          isNot(contains('private')),
        ),
      );
    });

    test('ignores URLs that are not on googlevideo', () async {
      final logs = <String>[];
      await diagnoseNativePlayback(
        'video-id',
        'https://example.com/a',
        {},
        logs.add,
        load: (_, _) async => throw StateError('unexpected'),
      );
      expect(logs, isEmpty);
    });
  });
}
