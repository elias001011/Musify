import '../channels/channel_id.dart';
import '../common/common.dart';
import '../extensions/helpers_extension.dart';
import '../reverse_engineering/youtube_http_client.dart';
import '../videos/video.dart';
import '../videos/video_id.dart';

/// A release (album, single or EP) as listed on a YouTube Music artist page.
class MusicAlbum {
  const MusicAlbum(this.id, this.title);

  /// Browse id of the release, e.g. `MPREb_...`.
  final String id;

  /// Display title of the release.
  final String title;

  @override
  String toString() => 'MusicAlbum($id, $title)';
}

/// Queries the YouTube Music (`WEB_REMIX`) browse endpoints.
///
/// This is a deliberately small, isolated client that only exposes what is
/// needed to build a structured artist discography (artist -> releases ->
/// tracks). It reuses [YoutubeHttpClient.sendPost] so it shares the same
/// retry/proxy behaviour as the rest of the library.
class MusicClient {
  /// Initializes an instance of [MusicClient].
  const MusicClient(this._httpClient);

  final YoutubeHttpClient _httpClient;

  static const _remixContext = {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20240101.01.00',
      'hl': 'en',
    },
  };

  /// Search filter that restricts results to artists only.
  static const _artistsSearchParams = 'EgWKAQIgAWoMEA4QChADEAQQCRAF';

  static const _artistPageType = 'MUSIC_PAGE_TYPE_ARTIST';

  /// Searches YouTube Music for artists matching [query].
  ///
  /// Returns the canonical artist entries (channel id + display name). The
  /// first entry is the best match. Only the canonical artist channel exposes
  /// a complete discography, so callers should resolve through this rather than
  /// browsing an arbitrary `- Topic` channel id.
  Future<List<({String id, String name})>> searchArtists(String query) async {
    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': query,
      'params': _artistsSearchParams,
    });

    final results = <({String id, String name})>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final endpoint = item.get('navigationEndpoint')?.get('browseEndpoint');
      final id = endpoint?.getT<String>('browseId');
      if (id == null || !id.startsWith('UC') || !seen.add(id)) continue;

      final pageType = endpoint
          ?.get('browseEndpointContextSupportedConfigs')
          ?.get('browseEndpointContextMusicConfig')
          ?.getT<String>('pageType');
      if (pageType != _artistPageType) continue;

      results.add((id: id, name: _firstFlexColumnText(item) ?? ''));
    }
    return results;
  }

  Future<JsonMap> _browse(String browseId, {String? params}) {
    // sendPost merges this map after its default context, so passing a
    // `context` key here overrides the default `WEB` client with `WEB_REMIX`.
    return _httpClient.sendPost('browse', {
      'context': _remixContext,
      'browseId': browseId,
      if (params != null) 'params': params,
    });
  }

  /// Returns the full discography (albums, singles and EPs) of a YouTube Music
  /// artist. The artist is identified by its channel id (the same `UC...` id
  /// used by a `- Topic` channel).
  ///
  /// The releases shown directly on the artist page are collected first, and
  /// any "more" button (the full album grid) is expanded as well so the result
  /// matches what YouTube Music shows.
  Future<List<MusicAlbum>> getArtistReleases(dynamic channelId) async {
    final id = ChannelId.fromString(channelId).value;
    final root = await _browse(id);

    final releases = <String, MusicAlbum>{};
    _collectReleases(root, releases);

    // Expand "more" grids (e.g. MPAD... for the full album list).
    for (final more in _collectMoreReleaseBrowses(root)) {
      try {
        final grid = await _browse(more.$1, params: more.$2);
        _collectReleases(grid, releases);
      } catch (_) {
        // A failing expansion just means we keep the inline releases.
      }
    }

    return releases.values.toList();
  }

  /// Returns the tracks of a release as [Video]s.
  ///
  /// [author] is used as the video author so downstream formatting keeps the
  /// resolved artist name even when YouTube Music omits it on a row.
  Future<List<Video>> getAlbumTracks(
    String albumBrowseId, {
    required String author,
    String? channelId,
  }) async {
    final root = await _browse(albumBrowseId);
    final resolvedChannelId = (channelId != null && channelId.isNotEmpty)
        ? ChannelId.fromString(channelId)
        : ChannelId('UC0000000000000000000000');

    final videos = <Video>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _firstFlexColumnText(item);
      if (title == null || title.isEmpty) continue;

      videos.add(
        Video(
          VideoId(videoId),
          title,
          author,
          resolvedChannelId,
          null,
          null,
          null,
          '',
          _parseDuration(_fixedColumnText(item)),
          ThumbnailSet(videoId),
          null,
          const Engagement(0, null, null),
          false,
        ),
      );
    }

    return videos;
  }

  void _collectReleases(JsonMap root, Map<String, MusicAlbum> into) {
    for (final item in _findRenderers(root, 'musicTwoRowItemRenderer')) {
      final browseId = item
          .get('navigationEndpoint')
          ?.get('browseEndpoint')
          ?.getT<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPRE')) continue;

      final title = item
          .get('title')
          ?.getList('runs')
          ?.cast<Map<dynamic, dynamic>>()
          .parseRuns();
      into.putIfAbsent(
        browseId,
        () => MusicAlbum(browseId, title?.trim() ?? ''),
      );
    }
  }

  /// Finds "more" buttons that point to a release grid (browseId + params).
  List<(String, String?)> _collectMoreReleaseBrowses(JsonMap root) {
    final result = <(String, String?)>[];
    for (final header in _findRenderers(
      root,
      'musicCarouselShelfBasicHeaderRenderer',
    )) {
      final endpoint = header
          .get('moreContentButton')
          ?.get('buttonRenderer')
          ?.get('navigationEndpoint')
          ?.get('browseEndpoint');
      final browseId = endpoint?.getT<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPAD')) continue;
      result.add((browseId, endpoint?.getT<String>('params')));
    }
    return result;
  }

  String? _trackVideoId(JsonMap item) {
    return item
        .get('overlay')
        ?.get('musicItemThumbnailOverlayRenderer')
        ?.get('content')
        ?.get('musicPlayButtonRenderer')
        ?.get('playNavigationEndpoint')
        ?.get('watchEndpoint')
        ?.getT<String>('videoId');
  }

  String? _firstFlexColumnText(JsonMap item) {
    final columns = item.getList('flexColumns');
    if (columns == null || columns.isEmpty) return null;
    return columns.first
        .get('musicResponsiveListItemFlexColumnRenderer')
        ?.get('text')
        ?.getList('runs')
        ?.cast<Map<dynamic, dynamic>>()
        .parseRuns();
  }

  String? _fixedColumnText(JsonMap item) {
    final columns = item.getList('fixedColumns');
    if (columns == null || columns.isEmpty) return null;
    return columns.last
        .get('musicResponsiveListItemFixedColumnRenderer')
        ?.get('text')
        ?.getList('runs')
        ?.cast<Map<dynamic, dynamic>>()
        .parseRuns();
  }

  Duration? _parseDuration(String? value) {
    if (value == null) return null;
    final parts = value.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;

    var seconds = 0;
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(seconds: seconds);
  }

  /// Depth-first search for every occurrence of [rendererKey], returning the
  /// renderer maps. Resilient to layout shuffles in the innertube response.
  Iterable<JsonMap> _findRenderers(dynamic node, String rendererKey) sync* {
    if (node is Map) {
      final match = node[rendererKey];
      if (match is Map) yield match.cast<String, dynamic>();
      for (final value in node.values) {
        yield* _findRenderers(value, rendererKey);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _findRenderers(value, rendererKey);
      }
    }
  }
}
