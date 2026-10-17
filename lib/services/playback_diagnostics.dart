import 'package:http/http.dart' as http;

/// HTTP diagnostics for debug builds. Signed URLs and headers stay out of logs.
class PlaybackDiagnosticClient extends http.BaseClient {
  PlaybackDiagnosticClient(this._log, {http.Client? inner})
    : _inner = inner ?? http.Client();

  final void Function(String) _log;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final endpoint = '${request.method} ${request.url.host}';
    try {
      final response = await _inner.send(request);
      _log('YouTube HTTP $endpoint: ${response.statusCode}');
      return response;
    } catch (e) {
      _log('YouTube HTTP $endpoint failed: ${e.runtimeType}');
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// On a player failure, distinguish a CDN rejection from an Android/local
/// player failure using a small GET with the same playback headers.
Future<void> diagnosePlaybackSource(
  String songId,
  String songUrl,
  Map<String, String> headers,
  void Function(String) log, {
  http.Client? client,
}) async {
  final uri = Uri.tryParse(songUrl);
  if (uri == null || !uri.host.endsWith('.googlevideo.com')) return;
  final transport = client ?? http.Client();
  try {
    final request = http.Request('GET', uri)
      ..headers.addAll(headers)
      ..headers['range'] = 'bytes=0-1023';
    final response = await transport
        .send(request)
        .timeout(const Duration(seconds: 5));
    log(
      'Playback probe $songId (${uri.host}): HTTP ${response.statusCode}; '
      'content-type=${response.headers['content-type'] ?? 'unknown'}',
    );
    // Cancel immediately, even if the server ignores Range and sends all audio.
    await response.stream.listen((_) {}).cancel();
  } catch (e) {
    log('Playback probe $songId failed: ${e.runtimeType}');
  } finally {
    transport.close();
  }
}
