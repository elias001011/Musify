import 'package:musify/services/playback_diagnostics.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Clients tried in order - the next one is used only if the previous fails
const fallbackClients = [YoutubeApiClient.visionOs, YoutubeApiClient.android];

// Client that produced the stream URL of each song, so playback can send
// the matching headers.
final Map<String, YoutubeApiClient> _songClients = {};

/// Receives diagnostic messages; `Logger.log` fits this signature.
typedef DiagnosticLog = void Function(
  String message, {
  Object? error,
  StackTrace? stackTrace,
});

String _clientName(YoutubeApiClient client) =>
    '${client.payload['context']?['client']?['clientName']}';

/// Tries each of [fallbackClients] in turn and returns the first manifest that
/// has audio. When [log] is given, every attempt reports its client, how long
/// it took, and (when it fails) the full exception, so a failure of the first
/// client is not lost when a later one also fails.
Future<StreamManifest> getManifestWithFallback(
  YoutubeExplode yt,
  String songId, {
  required Duration timeout,
  DiagnosticLog? log,
}) async {
  Object? lastError;
  StackTrace? lastStack;

  for (final client in fallbackClients) {
    final stopwatch = Stopwatch()..start();
    try {
      final manifest = await yt.videos.streams
          .getManifest(songId, ytClients: [client])
          .timeout(timeout);
      if (manifest.audioOnly.isEmpty) {
        throw VideoUnavailableException('No audio streams for "$songId"');
      }
      _songClients[songId] = client;
      log?.call(
        'getManifestWithFallback: ${_clientName(client)} resolved $songId in '
        '${stopwatch.elapsedMilliseconds}ms',
      );
      return manifest;
    } catch (e, s) {
      log?.call(
        'getManifestWithFallback: ${_clientName(client)} failed for $songId '
        'after ${stopwatch.elapsedMilliseconds}ms '
        '(timeout ${timeout.inSeconds}s, ${e.runtimeType})',
        error: redactUrls('$e'),
        stackTrace: s,
      );
      lastError = e;
      lastStack = s;
    }
  }

  Error.throwWithStackTrace(lastError!, lastStack!);
}

/// Headers googlevideo.com expects for URLs minted by the client that served
/// [songId]; a mismatched User-Agent can cause HTTP 403.
Map<String, String> streamPlaybackHeaders(String? songId) {
  final client = _songClients[songId] ?? fallbackClients.first;
  final userAgent = client.payload['context']?['client']?['userAgent'];
  return {
    if (userAgent is String) 'user-agent': userAgent,
    for (final entry in client.headers.entries) entry.key: '${entry.value}',
  };
}
