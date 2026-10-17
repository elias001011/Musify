import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// Run inside this package: dart run tool/diagnose_playback.dart [video-id]
// Logs HTTP status and endpoint only; signed URLs and cookies are omitted.
Future<void> main(List<String> args) async {
  final videoId = args.isEmpty ? 'jNQXAC9IVRw' : args.single;
  for (final client in [YoutubeApiClient.visionOs, YoutubeApiClient.android]) {
    final name = client.payload['context']['client']['clientName'];
    final transport = _DiagnosticClient();
    final yt = YoutubeExplode(httpClient: YoutubeHttpClient(transport));
    stdout.writeln('Video $videoId; client $name');
    try {
      final manifest = await yt.videos.streams.getManifest(videoId,
          ytClients: [client]).timeout(const Duration(seconds: 45));
      stdout.writeln('Audio streams: ${manifest.audioOnly.length}');
      final stream = manifest.audioOnly.withHighestBitrate();
      final userAgent = client.payload['context']['client']['userAgent'];
      final request = http.Request('GET', stream.url)
        ..headers.addAll({
          if (userAgent is String) 'user-agent': userAgent,
          for (final entry in client.headers.entries)
            entry.key: '${entry.value}',
          'range': 'bytes=0-1023',
        });
      final response =
          await transport.send(request).timeout(const Duration(seconds: 15));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final bytes = await response.stream.first.timeout(
          const Duration(seconds: 15),
        );
        stdout.writeln(
            'Received ${bytes.length} audio bytes; itag ${stream.tag}');
      }
    } catch (e) {
      // Exceptions may embed signed URLs, so only print their type here.
      stdout.writeln('Extraction failed: ${e.runtimeType}');
    } finally {
      yt.close();
    }
  }
}

class _DiagnosticClient extends http.BaseClient {
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    stdout.writeln('${request.method} ${request.url.host}: '
        'HTTP ${response.statusCode}; ${response.headers['content-type'] ?? ''}');
    return response;
  }

  @override
  void close() => _inner.close();
}
