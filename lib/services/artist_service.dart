/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Musify is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about Musify, including how to contribute,
 *     please visit: https://github.com/gokadzev/Musify
 */

import 'dart:async';

import 'package:musify/main.dart' show logger;
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/proxy_manager.dart';
import 'package:musify/utilities/formatter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const artistCatalogCacheVersion = 14;
const artistSearchCacheVersion = 9;
const _maxArtistUploadPages = 500;
const _artistRequestTimeout = Duration(seconds: 12);
const _artistUploadsPlaylistTimeout = Duration(minutes: 3);

class _ArtistSource {
  const _ArtistSource(this.artist);

  final Map<String, dynamic> artist;

  String get id => artist['ytid']?.toString() ?? '';
  String get title => artist['title']?.toString() ?? '';
}

Future<List<Map<String, dynamic>>> searchVerifiedArtists(
  String query, {
  int limit = 5,
}) async {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return [];

  final cacheKey =
      'search_topic_artists_v${artistSearchCacheVersion}_l$limit'
      '_${normalizedQuery.toLowerCase()}';
  final cachedArtists = await getData('cache', cacheKey);
  if (cachedArtists is List) {
    return cachedArtists
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .take(limit)
        .toList();
  }

  final topicSources = <_ArtistSource>[
    ...await _topicSourcesFromSearchQuery(normalizedQuery, limit: limit),
  ];

  if (_dedupeArtistSources(topicSources).length < limit) {
    final channelCandidates = await _searchArtistChannels(
      normalizedQuery,
      limit: limit * 4,
      verifiedOnly: false,
      maxPages: 3,
    );
    for (final candidate in channelCandidates) {
      final candidateTitles = _artistLookupTitles(candidate);
      final resolvedSources = await _resolveTopicSourcesForTitles(
        candidateTitles,
      );
      for (final source in resolvedSources) {
        if (_artistTitleMatchesSearchQuery(source.title, normalizedQuery) ||
            _artistTitleMatchesSearchQuery(
              candidate['title']?.toString() ?? '',
              normalizedQuery,
            )) {
          topicSources.add(source);
        }
      }
      if (_dedupeArtistSources(topicSources).length >= limit) break;
    }
  }

  final artists = _dedupeResolvedArtists(
    _dedupeArtistSources(topicSources).map(
      (source) => _withResolvedArtistMetadata({
        ...source.artist,
        'isVerifiedArtist': true,
        'source': 'youtube-artist',
        'isArtist': true,
        'list': [],
      }, preferredTitle: source.title),
    ),
  ).take(limit).toList();

  if (artists.isNotEmpty) {
    unawaited(addOrUpdateData<List>('cache', cacheKey, artists));
  }
  return artists;
}

Future<Map<String, dynamic>?> resolveArtist(
  String lookup, {
  String? sourceSongId,
  String? sourceVideoAuthor,
  String? preferredName,
  String? preferredImage,
  bool preferredVerified = false,
}) async {
  final normalizedLookup = lookup.trim();
  if (normalizedLookup.isEmpty || normalizedLookup == 'null') return null;

  final displayName = preferredName?.trim();
  final seedId = _isChannelId(normalizedLookup) ? normalizedLookup : null;
  final normalizedSourceSongId = sourceSongId?.trim();
  final candidates = <Map<String, dynamic>>[];
  var resolvedSourceVideoAuthor = sourceVideoAuthor?.trim();
  String? sourceVideoArtist;
  String? sourceChannelId;

  if (seedId != null) {
    try {
      final channel = await ytClient.channels.get(seedId);
      candidates.add(
        _artistMapFromChannel(channel, isVerifiedArtist: preferredVerified),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Could not load seeded artist channel $seedId',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  if (normalizedSourceSongId != null && normalizedSourceSongId.isNotEmpty) {
    try {
      final sourceVideo = await ytClient.videos.get(normalizedSourceSongId);
      resolvedSourceVideoAuthor = sourceVideo.author.trim();
      sourceVideoArtist = _artistNameFromVideoTitle(sourceVideo.title);
      sourceChannelId = sourceVideo.channelId.toString();
      if (_isChannelId(sourceChannelId)) {
        final channel = await ytClient.channels.get(sourceChannelId);
        candidates.add(_artistMapFromChannel(channel));
      }
    } catch (e, stackTrace) {
      logger.log(
        'Could not load source video $normalizedSourceSongId for artist lookup',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  final searchTerms = <String>{
    if (displayName != null && displayName.isNotEmpty)
      ..._artistSearchAliases(displayName),
    if (sourceVideoArtist != null && sourceVideoArtist.isNotEmpty)
      ..._artistSearchAliases(sourceVideoArtist),
    if (resolvedSourceVideoAuthor != null &&
        resolvedSourceVideoAuthor.isNotEmpty)
      ..._artistSearchAliases(
        _cleanArtistSearchTerm(resolvedSourceVideoAuthor),
      ),
    if (seedId != null)
      for (final candidate in candidates)
        ..._artistSearchAliases(
          _cleanArtistSearchTerm(candidate['title']?.toString() ?? ''),
        ),
    if (seedId == null &&
        normalizedLookup.isNotEmpty &&
        normalizedLookup != normalizedSourceSongId)
      ..._artistSearchAliases(normalizedLookup),
  }.where((term) => term.trim().isNotEmpty).toSet();

  final scoringName =
      displayName ??
      sourceVideoArtist ??
      _cleanArtistSearchTerm(resolvedSourceVideoAuthor ?? normalizedLookup);
  final topicLookupTitles = _artistLookupTitlesFromValues({
    scoringName,
    ...searchTerms,
    for (final candidate in candidates)
      _sourceArtistTitle(Map<String, dynamic>.from(candidate)),
  });
  final directTopicSources = await _resolveTopicSourcesForTitles(
    topicLookupTitles,
  );
  if (directTopicSources.isNotEmpty) {
    final topicArtist = Map<String, dynamic>.from(
      directTopicSources.first.artist,
    );
    if ((topicArtist['image'] == null ||
            topicArtist['image'].toString().isEmpty) &&
        preferredImage != null &&
        preferredImage.isNotEmpty) {
      topicArtist['image'] = normalizeArtistThumbnailUrl(preferredImage);
    }
    return _withResolvedArtistMetadata({
      ...topicArtist,
      'isVerifiedArtist': true,
      'source': 'youtube-artist',
      'isArtist': true,
      'list': [],
    }, preferredTitle: scoringName);
  }

  for (final searchTerm in searchTerms) {
    candidates.addAll(
      await _searchArtistChannels(searchTerm, limit: 10, verifiedOnly: false),
    );
  }

  final uniqueCandidates = _dedupeArtists(candidates);
  if (uniqueCandidates.isEmpty) {
    logger.log(
      'Artist lookup rejected: no candidates for "$normalizedLookup"; '
      'sourceSongId=$normalizedSourceSongId; preferredName=$displayName',
    );
    return null;
  }

  final verifiedCandidates = uniqueCandidates.where((candidate) {
    return _isVerifiedArtist(candidate) &&
        _isLikelySameArtist(candidate, scoringName);
  }).toList();
  final exactTopicCandidates = uniqueCandidates.where((candidate) {
    final candidateName = _sourceArtistTitle(candidate);
    return isExactArtistTopicTitle(candidateName, scoringName);
  }).toList();

  final officialCandidates = verifiedCandidates.isNotEmpty
      ? _dedupeArtists([...verifiedCandidates, ...exactTopicCandidates])
      : uniqueCandidates.where((candidate) {
          return _isLikelyOfficialArtistCandidate(
            candidate,
            preferredName: scoringName,
          );
        }).toList();

  if (officialCandidates.isEmpty) {
    logger.log(
      'Artist lookup rejected: no official/verified candidate for '
      '"$normalizedLookup"; sourceSongId=$normalizedSourceSongId; '
      'preferredName=$displayName',
    );
    return null;
  }

  officialCandidates.sort((a, b) {
    final scoreA = _scoreArtistCandidate(
      a,
      preferredName: scoringName,
      seedId: seedId,
      sourceChannelId: sourceChannelId,
    );
    final scoreB = _scoreArtistCandidate(
      b,
      preferredName: scoringName,
      seedId: seedId,
      sourceChannelId: sourceChannelId,
    );
    return scoreB.compareTo(scoreA);
  });

  final best = Map<String, dynamic>.from(officialCandidates.first);
  if ((best['image'] == null || best['image'].toString().isEmpty) &&
      preferredImage != null &&
      preferredImage.isNotEmpty) {
    best['image'] = normalizeArtistThumbnailUrl(preferredImage);
  }

  final bestId = best['ytid']?.toString();
  if (bestId != null && _isChannelId(bestId)) {
    try {
      final channel = await ytClient.channels.get(bestId);
      final refreshed = _artistMapFromChannel(
        channel,
        isVerifiedArtist: _isVerifiedArtist(best),
      );
      final merged = {
        ...refreshed,
        ...best,
        'image': normalizeArtistThumbnailUrl(
          best['image']?.toString() ?? refreshed['image']?.toString(),
        ),
        'bannerImage': normalizeArtistThumbnailUrl(
          refreshed['bannerImage']?.toString() ??
              best['bannerImage']?.toString(),
        ),
      };
      return _withResolvedArtistMetadata(merged, preferredTitle: scoringName);
    } catch (e, stackTrace) {
      logger.log(
        'Could not refresh artist channel $bestId',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  return _withResolvedArtistMetadata({
    ...best,
    'image': normalizeArtistThumbnailUrl(best['image']?.toString()),
  }, preferredTitle: scoringName);
}

Future<Map<String, dynamic>?> getArtistCatalog(
  String artistId, {
  bool forceRefresh = false,
  String? sourceSongId,
  String? sourceVideoAuthor,
  String? preferredName,
  String? preferredImage,
  bool preferredVerified = false,
}) async {
  try {
    final artist = await resolveArtist(
      artistId,
      preferredName: preferredName,
      preferredImage: preferredImage,
      sourceSongId: sourceSongId,
      sourceVideoAuthor: sourceVideoAuthor,
      preferredVerified: preferredVerified,
    );

    if (artist == null) {
      logger.log(
        'Artist catalog not found: lookup=$artistId; '
        'sourceSongId=$sourceSongId; preferredName=$preferredName',
      );
      return null;
    }

    final resolvedArtistId = artist['ytid']?.toString() ?? artistId;
    final cacheKey =
        'artist_catalog_v${artistCatalogCacheVersion}_$resolvedArtistId';
    if (!forceRefresh) {
      final cachedArtist = await getData('cache', cacheKey);
      if (cachedArtist is Map &&
          cachedArtist['list'] is List &&
          (cachedArtist['list'] as List).isNotEmpty) {
        final typedCachedArtist = Map<String, dynamic>.from(cachedArtist);
        final isComplete =
            typedCachedArtist['isCatalogComplete'] == true ||
            typedCachedArtist['catalogStatus'] == 'complete';
        if (isComplete) {
          return typedCachedArtist;
        }
      }
    } else {
      await deleteData('cache', cacheKey);
      await deleteData('cache', '${cacheKey}_date');
    }

    final songs = await _buildArtistCatalog(artist);
    final hasSongs = songs.isNotEmpty;
    if (!hasSongs) {
      logger.log(
        'Artist catalog not found: no exact Topic catalog for '
        '${artist['title']} (${artist['ytid']}); lookup=$artistId; '
        'sourceSongId=$sourceSongId; preferredName=$preferredName',
      );
      return null;
    }

    final artistPlaylist = {
      ...artist,
      'source': 'youtube-artist',
      'isArtist': true,
      'catalogStatus': 'complete',
      'isCatalogComplete': true,
      'list': songs,
    };

    if (songs.isNotEmpty) {
      unawaited(addOrUpdateData<Map>('cache', cacheKey, artistPlaylist));
    }
    return artistPlaylist;
  } catch (e, stackTrace) {
    logger.log(
      'Error fetching artist catalog for $artistId',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

String? normalizeArtistThumbnailUrl(String? value) {
  final thumbnail = value?.trim();
  if (thumbnail == null || thumbnail.isEmpty) return null;

  if (thumbnail.startsWith('//')) {
    return 'https:$thumbnail';
  }

  if (thumbnail.startsWith('https:') && !thumbnail.startsWith('https://')) {
    return 'https://${thumbnail.substring(6).replaceFirst(RegExp('^/+'), '')}';
  }

  if (thumbnail.startsWith('http:') && !thumbnail.startsWith('http://')) {
    return 'https://${thumbnail.substring(5).replaceFirst(RegExp('^/+'), '')}';
  }

  if (thumbnail.startsWith('http://') || thumbnail.startsWith('https://')) {
    return thumbnail;
  }

  if (thumbnail.startsWith('/')) {
    return 'https://www.youtube.com$thumbnail';
  }

  return 'https://$thumbnail';
}

String normalizeArtistDisplayTitle(String value) =>
    _cleanArtistSearchTerm(value);

bool isExactArtistTopicTitle(String topicTitle, String artistTitle) {
  if (!_isTopicArtistTitle(topicTitle)) return false;
  if (looksUnofficialArtistName(topicTitle)) return false;

  return _strictSameArtistTitle(topicTitle, artistTitle);
}

bool looksUnofficialArtistName(String name) {
  final lowerName = name.toLowerCase();
  return lowerName.contains('cover') ||
      lowerName.contains('lyrics') ||
      lowerName.contains('lyric') ||
      lowerName.contains('reaction') ||
      lowerName.contains('fan') ||
      lowerName.contains('tribute') ||
      lowerName.contains('karaoke') ||
      lowerName.contains('parody') ||
      lowerName.contains('nightcore') ||
      lowerName.contains('sped up') ||
      lowerName.contains('slowed');
}

List<Map<String, dynamic>> dedupeArtistCatalogSongs(
  List<Map<String, dynamic>> songs,
) {
  final seenIds = <String>{};
  final seenTitles = <String>{};
  final unique = <Map<String, dynamic>>[];
  for (final song in songs) {
    final id = song['ytid']?.toString();
    if (id == null || id.isEmpty || !seenIds.add(id)) continue;

    final title = formatSongTitle(song['title']?.toString() ?? '');
    final artist = song['artist']?.toString() ?? '';
    if (title.trim().isEmpty || _sameArtistPageSongTitle(title, artist)) {
      continue;
    }

    final titleKey =
        '${_canonicalArtistName(artist)}:${_canonicalSongTitle(title)}';
    if (!seenTitles.add(titleKey)) {
      continue;
    }

    unique.add({...song, 'id': unique.length, 'title': title});
  }
  return unique;
}

Future<List<Map<String, dynamic>>> _searchArtistChannels(
  String query, {
  required int limit,
  required bool verifiedOnly,
  int maxPages = 4,
}) async {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return [];

  final cacheKey =
      'search_artists_v${artistSearchCacheVersion}_${verifiedOnly ? 'verified' : 'all'}'
      '_l${limit}_p${maxPages}_${normalizedQuery.toLowerCase()}';
  final cachedArtists = await getData('cache', cacheKey);
  if (cachedArtists is List) {
    return cachedArtists
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .where(
          (artist) => _artistSearchResultMatchesQuery(artist, normalizedQuery),
        )
        .where((artist) => !verifiedOnly || _isVerifiedArtist(artist))
        .take(limit)
        .toList();
  }

  try {
    var results = await ytClient.search
        .searchContent(normalizedQuery, filter: TypeFilters.channel)
        .timeout(_artistRequestTimeout);

    final seen = <String>{};
    final artists = <Map<String, dynamic>>[];
    var searchedPages = 0;

    while (artists.length < limit && searchedPages < maxPages) {
      for (final result in results.whereType<SearchChannel>()) {
        final artist = _artistMapFromSearchChannel(result);
        final artistId = artist['ytid']?.toString();
        if (artistId == null || artistId.isEmpty || !seen.add(artistId)) {
          continue;
        }
        if (looksUnofficialArtistName(artist['title']?.toString() ?? '')) {
          continue;
        }
        if (!_artistSearchResultMatchesQuery(artist, normalizedQuery)) {
          continue;
        }
        if (verifiedOnly && !_isVerifiedArtist(artist)) {
          continue;
        }
        artists.add(artist);
        if (artists.length >= limit) break;
      }

      if (artists.length >= limit) break;
      searchedPages++;
      if (searchedPages >= maxPages) break;

      final nextPage = await results.nextPage().timeout(_artistRequestTimeout);
      if (nextPage == null || nextPage.isEmpty) break;
      results = nextPage;
    }

    unawaited(addOrUpdateData<List>('cache', cacheKey, artists));
    return artists;
  } catch (e, stackTrace) {
    logger.log(
      'Error while searching artists',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

Future<List<Map<String, dynamic>>> _buildArtistCatalog(
  Map<String, dynamic> artist,
) async {
  final sources = await _officialArtistSources(artist);
  final songs = <Map<String, dynamic>>[];

  for (final source in sources) {
    final channelSongs = await _loadArtistChannelSongs(source);
    songs.addAll(channelSongs);
  }

  final catalog = dedupeArtistCatalogSongs(songs);

  if (catalog.isEmpty) {
    logger.log(
      'Official artist catalog loaded with no songs: '
      '${artist['title']} (${artist['ytid']})',
    );
  }

  return catalog;
}

Future<List<_ArtistSource>> _officialArtistSources(
  Map<String, dynamic> artist,
) async {
  final artistId = artist['ytid']?.toString() ?? '';
  final artistTitles = _artistLookupTitles(artist);
  final exactTopicSources = await _resolveTopicSourcesForTitles(
    artistTitles,
    seedArtist: artist,
  );
  if (exactTopicSources.isNotEmpty) return exactTopicSources;

  logger.log(
    'Artist source rejected: no exact Topic source for '
    '${artist['title']} ($artistId)',
  );
  return [];
}

Future<List<_ArtistSource>> _resolveTopicSourcesForTitles(
  Set<String> artistTitles, {
  Map<String, dynamic>? seedArtist,
}) async {
  final topicSources = <_ArtistSource>[];

  if (artistTitles.isEmpty) return [];

  if (seedArtist != null &&
      _isChannelId(seedArtist['ytid']?.toString() ?? '') &&
      _isExactOfficialTopicSource(seedArtist, artistTitles)) {
    topicSources.add(_ArtistSource(seedArtist));
  }

  final topicCandidates = <Map<String, dynamic>>[];
  for (final artistTitle in artistTitles) {
    topicCandidates.addAll(
      await _searchArtistChannels(
        '$artistTitle - Topic',
        limit: 8,
        verifiedOnly: false,
        maxPages: 1,
      ),
    );
  }

  for (final candidate in topicCandidates) {
    if (_isExactOfficialTopicSource(candidate, artistTitles)) {
      topicSources.add(_ArtistSource(candidate));
    }
  }

  if (topicSources.isEmpty) {
    topicSources.addAll(await _topicSourcesFromVideoSearch(artistTitles));
  }

  return _dedupeArtistSources(topicSources);
}

List<_ArtistSource> _dedupeArtistSources(List<_ArtistSource> sources) {
  final deduped = <String, _ArtistSource>{};
  for (final source in sources) {
    if (source.id.isEmpty) continue;
    deduped[source.id] = source;
  }

  return deduped.values.toList();
}

List<Map<String, dynamic>> _dedupeResolvedArtists(
  Iterable<Map<String, dynamic>> artists,
) {
  final seenIds = <String>{};
  final seenTitles = <String>{};
  final unique = <Map<String, dynamic>>[];

  for (final artist in artists) {
    final id = artist['ytid']?.toString() ?? '';
    final titleKey = _strictArtistTitleKey(artist['title']?.toString() ?? '');
    if (id.isNotEmpty && !seenIds.add(id)) continue;
    if (titleKey.isNotEmpty && !seenTitles.add(titleKey)) continue;
    unique.add(artist);
  }

  return unique;
}

bool _isExactOfficialTopicSource(
  Map<String, dynamic> candidate,
  Set<String> artistTitles,
) {
  final sourceTitle = _sourceArtistTitle(candidate);
  return artistTitles.any(
    (artistTitle) => isExactArtistTopicTitle(sourceTitle, artistTitle),
  );
}

Future<List<_ArtistSource>> _topicSourcesFromVideoSearch(
  Set<String> artistTitles,
) async {
  final sources = <_ArtistSource>[];
  final seen = <String>{};

  for (final artistTitle in artistTitles) {
    try {
      final results = await ytClient.search
          .searchContent('$artistTitle - Topic', filter: TypeFilters.video)
          .timeout(_artistRequestTimeout);

      for (final result in results.whereType<SearchVideo>().take(20)) {
        if (!isExactArtistTopicTitle(result.author, artistTitle)) continue;

        final channelId = result.channelId.trim();
        if (!_isChannelId(channelId) || !seen.add(channelId)) continue;

        final source = {
          'ytid': channelId,
          'title': normalizeArtistDisplayTitle(result.author),
          'sourceTitle': result.author,
          'image': result.thumbnails.isNotEmpty
              ? normalizeArtistThumbnailUrl(
                  result.thumbnails.last.url.toString(),
                )
              : null,
          'source': 'youtube-artist',
          'isArtist': true,
          'isVerifiedArtist': true,
          'list': [],
        };
        if (_isExactOfficialTopicSource(source, artistTitles)) {
          sources.add(_ArtistSource(source));
        }
      }
    } catch (e, stackTrace) {
      logger.log(
        'Could not search Topic videos for artist $artistTitle',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  return sources;
}

Future<List<_ArtistSource>> _topicSourcesFromSearchQuery(
  String query, {
  required int limit,
}) async {
  final sources = <_ArtistSource>[];
  final seen = <String>{};
  final searchTerms = {query, '$query topic'};

  for (final searchTerm in searchTerms) {
    try {
      final results = await ytClient.search
          .searchContent(searchTerm, filter: TypeFilters.video)
          .timeout(_artistRequestTimeout);

      for (final result in results.whereType<SearchVideo>().take(30)) {
        if (!_isTopicArtistTitle(result.author)) continue;
        if (!_artistTitleMatchesSearchQuery(result.author, query)) continue;

        final channelId = result.channelId.trim();
        if (!_isChannelId(channelId) || !seen.add(channelId)) continue;

        sources.add(
          _ArtistSource({
            'ytid': channelId,
            'title': normalizeArtistDisplayTitle(result.author),
            'sourceTitle': result.author,
            'image': result.thumbnails.isNotEmpty
                ? normalizeArtistThumbnailUrl(
                    result.thumbnails.last.url.toString(),
                  )
                : null,
            'source': 'youtube-artist',
            'isArtist': true,
            'isVerifiedArtist': true,
            'list': [],
          }),
        );

        if (sources.length >= limit) return sources;
      }
    } catch (e, stackTrace) {
      logger.log(
        'Could not search Topic artists for query $query',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  return sources;
}

Future<List<Map<String, dynamic>>> _loadArtistChannelSongs(
  _ArtistSource source,
) async {
  final sourceId = source.id;
  if (!_isChannelId(sourceId)) return [];

  final songs = <Map<String, dynamic>>[];

  try {
    var page = await ytClient.channels
        .getUploadsFromPage(sourceId)
        .timeout(_artistRequestTimeout);
    var loadedPages = 0;

    while (loadedPages < _maxArtistUploadPages) {
      for (final video in page) {
        songs.add(returnSongLayout(songs.length, video));
      }

      loadedPages++;
      if (loadedPages >= _maxArtistUploadPages) break;

      final nextPage = await page.nextPage().timeout(_artistRequestTimeout);
      if (nextPage == null || nextPage.isEmpty) break;
      page = nextPage;
    }
  } catch (e, stackTrace) {
    logger.log(
      'Could not load channel upload pages for artist source '
      '${source.title} ($sourceId)',
      error: e,
      stackTrace: stackTrace,
    );
  }

  try {
    await for (final video
        in ytClient.channels
            .getUploads(sourceId)
            .timeout(_artistUploadsPlaylistTimeout)) {
      songs.add(returnSongLayout(songs.length, video));
    }
  } catch (e, stackTrace) {
    logger.log(
      'Could not load uploads playlist for artist source '
      '${source.title} ($sourceId)',
      error: e,
      stackTrace: stackTrace,
    );
  }

  return dedupeArtistCatalogSongs(songs);
}

Map<String, dynamic> _artistMapFromChannel(
  Channel channel, {
  bool isVerifiedArtist = false,
}) {
  return {
    'ytid': channel.id.toString(),
    'title': normalizeArtistDisplayTitle(channel.title),
    'sourceTitle': channel.title,
    'image': normalizeArtistThumbnailUrl(channel.logoUrl),
    'bannerImage': normalizeArtistThumbnailUrl(channel.bannerUrl),
    'subscribersCount': channel.subscribersCount,
    'source': 'youtube-artist',
    'isArtist': true,
    'isVerifiedArtist': isVerifiedArtist,
    'list': [],
  };
}

Map<String, dynamic> _artistMapFromSearchChannel(SearchChannel artist) {
  final thumbnail = artist.thumbnails.isNotEmpty
      ? artist.thumbnails.last.url.toString()
      : null;

  return {
    'ytid': artist.id.toString(),
    'title': normalizeArtistDisplayTitle(artist.name),
    'sourceTitle': artist.name,
    'image': normalizeArtistThumbnailUrl(thumbnail),
    'videoCount': artist.videoCount,
    'source': 'youtube-artist',
    'isArtist': true,
    'isVerifiedArtist': artist.isVerifiedArtist,
    'list': [],
  };
}

Map<String, dynamic> _withResolvedArtistMetadata(
  Map<String, dynamic> artist, {
  required String preferredTitle,
}) {
  final resolvedArtist = Map<String, dynamic>.from(artist);
  final sourceTitle = _sourceArtistTitle(resolvedArtist);
  final displayTitle = normalizeArtistDisplayTitle(
    resolvedArtist['title']?.toString() ?? sourceTitle,
  );
  final preferredDisplayTitle = normalizeArtistDisplayTitle(preferredTitle);

  if (displayTitle.isNotEmpty) {
    resolvedArtist['title'] = displayTitle;
  }

  if (preferredDisplayTitle.isNotEmpty) {
    resolvedArtist['lookupTitle'] = preferredDisplayTitle;
  }

  return resolvedArtist;
}

bool _isLikelyOfficialArtistCandidate(
  Map<String, dynamic> artist, {
  required String preferredName,
}) {
  final candidateName = _sourceArtistTitle(artist);
  if (!_isLikelySameArtist(artist, preferredName)) return false;
  if (looksUnofficialArtistName(candidateName)) return false;

  final lowerName = candidateName.toLowerCase();
  return _hasOfficialArtistSourceSignal(lowerName);
}

bool _isLikelySameArtist(Map<String, dynamic> artist, String preferredName) {
  final candidateName = _sourceArtistTitle(artist);
  if (_isTopicArtistTitle(candidateName)) {
    return _strictSameArtistTitle(candidateName, preferredName);
  }

  final canonicalCandidate = _canonicalArtistName(candidateName);
  final canonicalPreferred = _canonicalArtistName(preferredName);
  if (canonicalCandidate.isEmpty || canonicalPreferred.isEmpty) {
    return false;
  }

  return canonicalCandidate == canonicalPreferred ||
      canonicalCandidate.contains(canonicalPreferred) ||
      canonicalPreferred.contains(canonicalCandidate);
}

int _scoreArtistCandidate(
  Map<String, dynamic> artist, {
  required String preferredName,
  String? seedId,
  String? sourceChannelId,
}) {
  final candidateId = artist['ytid']?.toString();
  final candidateName = _sourceArtistTitle(artist);
  final canonicalCandidate = _canonicalArtistName(candidateName);
  final canonicalPreferred = _canonicalArtistName(preferredName);
  var score = 0;

  if (_isVerifiedArtist(artist)) {
    score += 500;
  }

  if (seedId != null && candidateId == seedId) {
    score += _isVevoArtistTitle(candidateName) ? 20 : 240;
  }

  if (sourceChannelId != null && candidateId == sourceChannelId) {
    score += _isVevoArtistTitle(candidateName) ? 40 : 180;
  }

  if (canonicalPreferred.isEmpty || canonicalCandidate.isEmpty) {
    return score;
  }

  if (canonicalCandidate == canonicalPreferred) {
    score += 130;
  } else if (canonicalCandidate.contains(canonicalPreferred) ||
      canonicalPreferred.contains(canonicalCandidate)) {
    score += 60;
  }

  final lowerName = candidateName.toLowerCase();
  if (_isTopicArtistTitle(candidateName)) {
    score += 360;
  } else if (lowerName.contains('official artist channel')) {
    score += 180;
  } else if (_isVevoArtistTitle(candidateName)) {
    score += 20;
  } else if (_hasOfficialArtistSourceSignal(lowerName)) {
    score += 30;
  }

  if (_isVevoArtistTitle(candidateName)) {
    score -= 200;
  }

  if (looksUnofficialArtistName(candidateName)) {
    score -= 220;
  }

  final videoCount = artist['videoCount'];
  if (videoCount is int && videoCount > 0) {
    score += 5;
  }

  final subscribers = artist['subscribersCount'];
  if (subscribers is int && subscribers >= 10000) {
    score += 10;
  }

  return score;
}

bool _hasOfficialArtistSourceSignal(String value) {
  final lower = value.toLowerCase();
  return lower.contains('official') ||
      lower.contains('vevo') ||
      lower.contains(' - topic') ||
      lower.endsWith(' topic') ||
      lower.contains('topic channel');
}

bool _artistSearchResultMatchesQuery(
  Map<String, dynamic> artist,
  String query,
) {
  final sourceTitle = _sourceArtistTitle(artist);
  if (!_isTopicArtistTitle(sourceTitle)) return true;

  return _strictSameArtistTitle(sourceTitle, query);
}

bool _artistTitleMatchesSearchQuery(String artistTitle, String query) {
  final titleKey = _strictArtistTitleKey(artistTitle);
  final queryKey = _strictArtistTitleKey(query);
  if (titleKey.isEmpty || queryKey.isEmpty) return false;

  if (titleKey == queryKey) return true;
  if (queryKey.length < 3) return false;
  if (titleKey.contains(queryKey)) return true;

  final queryWords = queryKey.split(' ');
  final titleWords = titleKey.split(' ');
  if (queryWords.length == 1) {
    final queryWord = queryWords.single;
    return titleWords.any((word) => word.startsWith(queryWord));
  }

  return false;
}

String _sourceArtistTitle(Map<String, dynamic> artist) {
  final sourceTitle = artist['sourceTitle']?.toString().trim();
  if (sourceTitle != null && sourceTitle.isNotEmpty) return sourceTitle;

  return artist['title']?.toString().trim() ?? '';
}

Set<String> _artistLookupTitles(Map<String, dynamic> artist) {
  final titles = <String>{};
  for (final key in const ['lookupTitle', 'title', 'sourceTitle']) {
    final title = artist[key]?.toString().trim();
    if (title == null || title.isEmpty) continue;

    final displayTitle = normalizeArtistDisplayTitle(title);
    if (displayTitle.isNotEmpty) {
      titles
        ..add(displayTitle)
        ..add(_spaceCamelCaseArtistTitle(displayTitle));
    }
  }

  return titles
      .where((title) => _strictArtistTitleKey(title).isNotEmpty)
      .toSet();
}

Set<String> _artistLookupTitlesFromValues(Set<String> values) {
  final titles = <String>{};
  for (final value in values) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) continue;

    titles.addAll(_artistLookupTitles({'title': cleaned}));
  }

  return titles;
}

String _spaceCamelCaseArtistTitle(String value) {
  if (value.length < 2) return value.trim();

  final buffer = StringBuffer(value[0]);
  for (var index = 1; index < value.length; index++) {
    final previous = value.codeUnitAt(index - 1);
    final current = value.codeUnitAt(index);
    final previousIsLower = previous >= 97 && previous <= 122;
    final currentIsUpper = current >= 65 && current <= 90;
    if (previousIsLower && currentIsUpper) {
      buffer.write(' ');
    }
    buffer.writeCharCode(current);
  }

  return buffer.toString().trim();
}

bool _isTopicArtistTitle(String value) {
  final lower = value.toLowerCase().trim();
  return RegExp(r'\s*-\s*topic$').hasMatch(lower) ||
      lower.endsWith(' topic channel');
}

bool _isVevoArtistTitle(String value) {
  return value.toLowerCase().trim().endsWith('vevo');
}

bool _strictSameArtistTitle(String left, String right) {
  final leftKey = _strictArtistTitleKey(left);
  final rightKey = _strictArtistTitleKey(right);

  return leftKey.isNotEmpty && leftKey == rightKey;
}

String _strictArtistTitleKey(String value) {
  return _cleanArtistSearchTerm(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\bofficial artist channel\b'), '')
      .replaceAll(RegExp(r'\bofficial channel\b'), '')
      .replaceAll(RegExp(r'\bmusic channel\b'), '')
      .replaceAll(RegExp(r'\bofficial\b'), '')
      .replaceAll(RegExp(r'\bvevo\b'), '')
      .replaceAll(RegExp('[^a-z0-9&]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

List<Map<String, dynamic>> _dedupeArtists(List<Map<String, dynamic>> artists) {
  final seen = <String>{};
  final unique = <Map<String, dynamic>>[];
  for (final artist in artists) {
    final id = artist['ytid']?.toString();
    final title = artist['title']?.toString();
    final key = (id != null && id.isNotEmpty) ? id : title;
    if (key == null || key.isEmpty || !seen.add(key)) continue;
    unique.add(artist);
  }
  return unique;
}

bool _sameArtistPageSongTitle(String title, String artist) {
  final canonicalTitle = _canonicalSongTitle(title);
  final canonicalArtist = _canonicalArtistName(artist);
  return canonicalTitle.isNotEmpty && canonicalTitle == canonicalArtist;
}

String _artistNameFromVideoTitle(String title) {
  final sep = title.indexOf(' - ');
  if (sep <= 0) return '';
  return title.substring(0, sep).trim();
}

Set<String> _artistSearchAliases(String value) {
  final cleaned = _cleanArtistSearchTerm(value);
  if (cleaned.isEmpty) return {};

  final aliases = <String>{cleaned};
  final featureSplit = cleaned.split(
    RegExp(r'\s+(?:feat\.?|ft\.?|featuring|with)\s+', caseSensitive: false),
  );
  if (featureSplit.first.trim().isNotEmpty) {
    aliases.add(featureSplit.first.trim());
  }

  final joinedArtists = cleaned.split(
    RegExp(r'\s+(?:x|\+|&)\s+', caseSensitive: false),
  );
  if (joinedArtists.first.trim().isNotEmpty) {
    aliases.add(joinedArtists.first.trim());
  }

  final commaParts = cleaned.split(',');
  if (commaParts.length > 1 && commaParts.first.trim().length > 3) {
    aliases.add(commaParts.first.trim());
  }

  return aliases.where((alias) => alias.trim().isNotEmpty).toSet();
}

String _cleanArtistSearchTerm(String value) {
  return _topicBaseTitle(_normalizeArtistText(value))
      .replaceAll(RegExp(r'\s*vevo\s*$', caseSensitive: false), '')
      .replaceAll(
        RegExp(r'\s*official artist channel\s*$', caseSensitive: false),
        '',
      )
      .trim();
}

String _topicBaseTitle(String value) {
  return _normalizeArtistText(value)
      .trim()
      .replaceAll(RegExp(r'\s*topic channel\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
      .trim();
}

String _normalizeArtistText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    buffer.writeCharCode(_normalizeStyledRune(rune) ?? rune);
  }
  return buffer.toString();
}

int? _normalizeStyledRune(int rune) {
  int? mapLetters(int upperStart, int lowerStart) {
    if (rune >= upperStart && rune <= upperStart + 25) {
      return 0x41 + rune - upperStart;
    }
    if (rune >= lowerStart && rune <= lowerStart + 25) {
      return 0x61 + rune - lowerStart;
    }
    return null;
  }

  int? mapDigits(int digitStart) {
    if (rune >= digitStart && rune <= digitStart + 9) {
      return 0x30 + rune - digitStart;
    }
    return null;
  }

  for (final range in const [
    (0x1D400, 0x1D41A), // mathematical bold
    (0x1D434, 0x1D44E), // mathematical italic
    (0x1D468, 0x1D482), // mathematical bold italic
    (0x1D4D0, 0x1D4EA), // mathematical bold script
    (0x1D56C, 0x1D586), // mathematical bold fraktur
    (0x1D5A0, 0x1D5BA), // mathematical sans-serif
    (0x1D5D4, 0x1D5EE), // mathematical sans-serif bold
    (0x1D608, 0x1D622), // mathematical sans-serif italic
    (0x1D63C, 0x1D656), // mathematical sans-serif bold italic
    (0x1D670, 0x1D68A), // mathematical monospace
    (0xFF21, 0xFF41), // fullwidth
  ]) {
    final mapped = mapLetters(range.$1, range.$2);
    if (mapped != null) return mapped;
  }

  for (final digitStart in const [
    0x1D7CE, // mathematical bold
    0x1D7D8, // mathematical double-struck
    0x1D7E2, // mathematical sans-serif
    0x1D7EC, // mathematical sans-serif bold
    0x1D7F6, // mathematical monospace
    0xFF10, // fullwidth
  ]) {
    final mapped = mapDigits(digitStart);
    if (mapped != null) return mapped;
  }

  return null;
}

String _canonicalSongTitle(String value) {
  return formatSongTitle(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(
        RegExp(r'\b(official|audio|video|lyrics?|visuali[sz]er)\b'),
        '',
      )
      .replaceAll(RegExp('[^a-z0-9]+'), '');
}

String _canonicalArtistName(String value) {
  final lower = _normalizeArtistText(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s*-\s*topic\b'), '')
      .replaceAll(RegExp(r'\bofficial artist channel\b'), '')
      .replaceAll(RegExp(r'\bofficial channel\b'), '')
      .replaceAll(RegExp(r'\bmusic channel\b'), '')
      .replaceAll(RegExp(r'\bofficial\b'), '')
      .trim();

  var cleaned = lower.replaceAll(RegExp('[^a-z0-9]+'), '');
  var previous = '';
  while (cleaned != previous) {
    previous = cleaned;
    cleaned = cleaned.replaceAll(
      RegExp(r'(official|music|channel|topic|vevo)$'),
      '',
    );
  }

  if (cleaned.isNotEmpty) return cleaned;

  return lower.replaceAll(RegExp(r'\s+'), '');
}

bool _isVerifiedArtist(Map<String, dynamic> artist) =>
    artist['isVerifiedArtist'] == true;

bool _isChannelId(String value) => ChannelId.validateChannelId(value);
