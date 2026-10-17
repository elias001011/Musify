import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Query parameters of a googlevideo URL that are safe to log. Everything else
/// (`sig`, `lsig`, `pot`, `n`, `ip`, `id`, ...) identifies or authorizes the
/// request and must never reach the log.
const _safeStreamUrlParams = [
  'itag',
  'mime',
  'c',
  'clen',
  'dur',
  'ratebypass',
  'source',
  'sq',
  'gir',
];

final _urlPattern = RegExp(r'''https?://[^\s"'<>)\]]+''');

/// Replaces every URL in [text] by `scheme://host/...`, so exception messages
/// can be logged without query strings, signatures or tokens.
String redactUrls(String text) => text.replaceAllMapped(_urlPattern, (m) {
  final uri = Uri.tryParse(m[0]!);
  if (uri == null || uri.host.isEmpty) return '<url>';
  return '${uri.scheme}://${uri.host}/...';
});

/// Describes a stream URL by host, scheme and a few non-sensitive parameters
/// (itag, mime, client, length, time to expiry). No signature or token.
String describeStreamUrl(String url, {DateTime? now}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return 'unparseable URL';
  // Path-style googlevideo URLs (HLS/DASH manifests) carry signatures in the
  // path, so only the plain progressive endpoint is spelled out.
  final showPath =
      uri.host.endsWith('googlevideo.com') && uri.path == '/videoplayback';
  final params = uri.queryParameters;
  final parts = <String>[
    '${uri.scheme}://${uri.host}${showPath ? uri.path : '/...'}',
    for (final key in _safeStreamUrlParams)
      if (params.containsKey(key)) '$key=${params[key]}',
  ];
  // The URL is bound to the address that requested it. Only the family is
  // logged, never the address: a v4/v6 mismatch between the app's request and
  // the player's request makes the CDN answer 403.
  final ip = InternetAddress.tryParse(params['ip'] ?? '');
  if (ip != null) {
    parts.add('boundToIp=${ip.type.name}');
  }
  final expire = int.tryParse(params['expire'] ?? '');
  if (expire != null) {
    final secondsLeft =
        expire - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    parts.add('expiresIn=${secondsLeft}s');
  }
  return parts.join(' ');
}

/// One-line description of an audio stream chosen for playback.
String describeAudioStream(AudioOnlyStreamInfo stream) {
  final codecs = stream.codec.parameters['codecs'] ?? stream.codec.subtype;
  return 'itag=${stream.tag} container=${stream.container.name} '
      'codec=${stream.codec.mimeType}/$codecs '
      'bitrate=${stream.bitrate.kiloBitsPerSecond.round()}kbps '
      'size=${stream.size.totalMegaBytes.toStringAsFixed(1)}MB '
      '${describeStreamUrl(stream.url.toString())}';
}

/// How many streams a manifest holds, by kind. Tells an empty/odd manifest
/// (only HLS, only video, no audio) from a normal one.
String describeManifest(StreamManifest manifest) =>
    'streams=${manifest.streams.length} audioOnly=${manifest.audioOnly.length} '
    'muxed=${manifest.muxed.length} videoOnly=${manifest.videoOnly.length} '
    'hls=${manifest.hls.length}';

/// Describes the [AudioSource] handed to the player, and whether just_audio
/// will route it through its cleartext loopback proxy (it does whenever
/// request headers are set on a non-file source).
String describeAudioSource(AudioSource source) {
  if (source is! UriAudioSource) return source.runtimeType.toString();
  final headers = source.headers;
  final userAgent = headers?.entries
      .where((e) => e.key.toLowerCase() == 'user-agent')
      .map((e) => e.value)
      .firstOrNull;
  final viaProxy = headers != null && source.uri.scheme != 'file';
  return '${source.runtimeType} ${describeStreamUrl(source.uri.toString())} '
      'headerNames=${headers?.keys.toList() ?? const []} '
      'userAgent=${userAgent ?? 'none'} '
      'viaJustAudioLoopbackProxy=$viaProxy';
}

/// What a player exception carries. just_audio only exposes the numeric type
/// and a generic message; the underlying ExoPlayer cause is in logcat
/// (`TYPE_SOURCE: ...` from the `AudioPlayer` tag).
String describePlayerError(Object error) {
  if (error is PlayerException) {
    return 'PlayerException code=${error.code} message=${error.message} '
        'index=${error.index}';
  }
  if (error is PlayerInterruptedException) {
    return 'PlayerInterruptedException message=${error.message}';
  }
  return '${error.runtimeType}: ${redactUrls(error.toString())}';
}

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

String _probeLabel(int? status) => status == null ? 'error' : '$status';

Future<int?> _probeStatus(
  http.Client client,
  Uri uri,
  Map<String, String> headers,
) async {
  try {
    final request = http.Request('GET', uri)
      ..headers.addAll(headers)
      ..headers['range'] = 'bytes=0-1023';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 5));
    await response.stream.listen((_) {}).cancel();
    return response.statusCode;
  } catch (_) {
    return null;
  }
}

/// Requests the same URL three times, changing only the User-Agent, to show
/// whether the CDN cares which one is sent:
///
/// - `client`: the User-Agent of the YouTube client that minted the URL.
/// - `dart`: what just_audio's loopback proxy really sends. Its `_getUrl`
///   overwrites any supplied User-Agent with `HttpClient().userAgent`.
/// - `exoplayer`: what ExoPlayer sends on its own, as before playback headers
///   were added in 10.5.3.
///
/// `client=206 dart=403` would prove the proxy's User-Agent override breaks
/// playback. Equal results mean the User-Agent is not the cause.
Future<void> diagnoseUserAgentVariants(
  String songId,
  String songUrl,
  Map<String, String> clientHeaders,
  void Function(String) log, {
  http.Client? client,
  String? dartUserAgent,
}) async {
  final uri = Uri.tryParse(songUrl);
  if (uri == null || !uri.host.endsWith('.googlevideo.com')) return;
  final transport = client ?? http.Client();
  try {
    final clientUa = clientHeaders['user-agent'];
    final dartUa = dartUserAgent ?? HttpClient().userAgent ?? 'Dart';
    const exoUa = 'just_audio/1.0 (Linux;Android) ExoPlayerLib/1.0';
    final results = <String, int?>{
      if (clientUa != null)
        'client': await _probeStatus(transport, uri, clientHeaders),
      'dart': await _probeStatus(transport, uri, {'user-agent': dartUa}),
      'exoplayer': await _probeStatus(transport, uri, {'user-agent': exoUa}),
    };
    log(
      'Playback probe User-Agent $songId (${uri.host}): '
      '${results.entries.map((e) => '${e.key}=${_probeLabel(e.value)}').join(' ')}',
    );
  } finally {
    transport.close();
  }
}

/// Smallest valid WAV (PCM 8-bit mono, 100 ms of silence).
Uint8List _silentWav() {
  const sampleRate = 8000;
  const samples = 800;
  final data = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_le32(36 + samples))
    ..add('WAVEfmt '.codeUnits)
    ..add(_le32(16))
    ..add([1, 0, 1, 0])
    ..add(_le32(sampleRate))
    ..add(_le32(sampleRate))
    ..add([1, 0, 8, 0])
    ..add('data'.codeUnits)
    ..add(_le32(samples))
    ..add(List<int>.filled(samples, 128));
  return data.toBytes();
}

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

/// Checks whether ExoPlayer is allowed to open an `http://127.0.0.1` URL, which
/// is what just_audio's header proxy needs (`android:usesCleartextTraffic`).
///
/// A throwaway player loads a silent WAV from a loopback server started here.
/// If the server saw the request the platform allows loopback cleartext. If
/// the player failed without the server seeing anything, it was blocked before
/// leaving the player (Android's "Cleartext HTTP traffic ... not permitted").
/// The player never plays and is disposed immediately.
Future<void> diagnoseLoopbackCleartext(
  void Function(String) log, {
  Future<void> Function(String url)? loadUrl,
}) async {
  HttpServer? server;
  AudioPlayer? player;
  var hits = 0;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final wav = _silentWav();
    server.listen((request) async {
      hits++;
      request.response
        ..headers.contentType = ContentType('audio', 'wav')
        ..headers.contentLength = wav.length
        ..add(wav);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/probe.wav';
    String outcome;
    try {
      if (loadUrl != null) {
        await loadUrl(url).timeout(const Duration(seconds: 5));
      } else {
        player = AudioPlayer(
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
          handleAudioSessionActivation: false,
        );
        await player.setUrl(url).timeout(const Duration(seconds: 5));
      }
      outcome = 'player loaded it';
    } catch (e) {
      outcome = 'player failed: ${describePlayerError(e)}';
    }
    log(
      'Loopback cleartext probe: serverRequests=$hits; $outcome. '
      '${hits > 0 ? 'The platform lets ExoPlayer reach 127.0.0.1.' : 'ExoPlayer never reached 127.0.0.1: cleartext to loopback is likely blocked.'}',
    );
  } catch (e) {
    log('Loopback cleartext probe could not run: ${e.runtimeType}');
  } finally {
    try {
      await player?.dispose();
    } catch (_) {}
    await server?.close(force: true);
  }
}

/// Loads [url] into a throwaway player, with or without request headers, and
/// reports how the platform player handled it. [load] is for tests.
Future<String> _tryNativeLoad(
  Uri url,
  Map<String, String>? headers,
  Future<void> Function(Uri url, Map<String, String>? headers)? load,
) async {
  AudioPlayer? player;
  try {
    if (load != null) {
      await load(url, headers).timeout(const Duration(seconds: 10));
    } else {
      player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      );
      await player
          .setAudioSource(AudioSource.uri(url, headers: headers))
          .timeout(const Duration(seconds: 10));
    }
    return 'ok';
  } catch (e) {
    return 'failed (${describePlayerError(e)})';
  } finally {
    try {
      await player?.dispose();
    } catch (_) {}
  }
}

/// Splits "the player cannot play this URL" into its possible causes by
/// loading the very URL that just failed into two throwaway players:
///
/// - `direct`: no headers, so ExoPlayer requests it with its own network
///   stack (how playback worked before 10.5.3).
/// - `viaProxy`: with the playback headers, so just_audio routes it through
///   its loopback proxy and the request is made by Dart's network stack.
///
/// `direct=ok viaProxy=failed` points at the proxy (cleartext, headers);
/// `direct=failed viaProxy=ok` at ExoPlayer's own connection (for example an
/// IPv4/IPv6 mismatch with the address the URL is bound to); both failing
/// while the HTTP probes succeed points at the media format or the device.
/// The players never play and are disposed immediately.
Future<void> diagnoseNativePlayback(
  String songId,
  String songUrl,
  Map<String, String> headers,
  void Function(String) log, {
  Future<void> Function(Uri url, Map<String, String>? headers)? load,
}) async {
  final uri = Uri.tryParse(songUrl);
  if (uri == null || !uri.host.endsWith('.googlevideo.com')) return;
  final direct = await _tryNativeLoad(uri, null, load);
  final viaProxy = await _tryNativeLoad(uri, headers, load);
  log(
    'Native player probe $songId (${uri.host}): direct=$direct '
    'viaProxy=$viaProxy',
  );
}
