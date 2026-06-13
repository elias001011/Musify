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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:musify/main.dart' show logger;
import 'package:musify/screens/playlist_page.dart';
import 'package:musify/services/playlists_manager.dart';
import 'package:musify/widgets/mini_player_bottom_space.dart';
import 'package:musify/widgets/playlist_page/empty_playlist_state.dart';
import 'package:musify/widgets/spinner.dart';

class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.artistId, this.artistData});

  final String artistId;
  final Map? artistData;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  static const _slowArtistLoadThreshold = Duration(seconds: 6);
  static const _completeArtistLoadTimeout = Duration(seconds: 120);

  late Future<Map?> _artistFuture;
  Map? _resolvedArtist;
  bool _artistNotFound = false;
  int _artistRevision = 0;

  @override
  void initState() {
    super.initState();
    _artistFuture = _loadArtist();
  }

  @override
  void didUpdateWidget(covariant ArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistId != widget.artistId ||
        oldWidget.artistData != widget.artistData) {
      _resolvedArtist = null;
      _artistNotFound = false;
      _artistFuture = _loadArtist();
    }
  }

  Future<Map?> _loadArtistCatalog() {
    final artistData = widget.artistData;
    return getPlaylistInfoForWidget(
      widget.artistId,
      isArtist: true,
      artistName: artistData?['title']?.toString(),
      artistImage: artistData?['image']?.toString(),
      sourceSongId: artistData?['sourceSongId']?.toString(),
      sourceVideoAuthor: artistData?['videoAuthor']?.toString(),
      preferredVerified: artistData?['isVerifiedArtist'] == true,
    );
  }

  Future<Map?> _loadArtist() async {
    final fullCatalogFuture = _loadArtistCatalog();
    final trustedSeed = _trustedSeedArtist();

    if (trustedSeed != null) {
      _finishFullCatalogInBackground(
        fullCatalogFuture,
        trustedSeed,
        showNotFoundOnNull: true,
      );
      return trustedSeed;
    }

    try {
      final artist = await fullCatalogFuture.timeout(_slowArtistLoadThreshold);
      if (artist == null) {
        final resolvingSeed = _resolvingSeedArtist();
        if (resolvingSeed != null) {
          _finishFullCatalogInBackground(
            _loadArtistCatalog(),
            resolvingSeed,
            showNotFoundOnNull: true,
          );
          return resolvingSeed;
        }
        _logNotFoundIfNeeded(artist);
        return null;
      }
      _logNotFoundIfNeeded(artist);
      return artist;
    } on TimeoutException {
      logger.log(
        'ArtistPage slow catalog load: lookup=${widget.artistId}; '
        'sourceSongId=${widget.artistData?['sourceSongId']}; '
        'showing resolving state while full load continues',
      );

      final resolvingSeed = _resolvingSeedArtist();
      if (resolvingSeed != null) {
        _finishFullCatalogInBackground(
          fullCatalogFuture,
          resolvingSeed,
          showNotFoundOnNull: true,
        );
        return resolvingSeed;
      }

      final artist = await fullCatalogFuture.timeout(
        _completeArtistLoadTimeout,
        onTimeout: () => null,
      );
      _logNotFoundIfNeeded(artist, reason: 'timeout/no official artist');
      return artist;
    } catch (e, stackTrace) {
      logger.log(
        'ArtistPage catalog load failed: lookup=${widget.artistId}',
        error: e,
        stackTrace: stackTrace,
      );
      final trustedSeed = _trustedSeedArtist();
      if (trustedSeed != null) {
        return {
          ...trustedSeed,
          'catalogStatus': 'failed',
          'isCatalogComplete': false,
        };
      }
      _logNotFoundIfNeeded(null, reason: 'load failed');
      return null;
    }
  }

  Map<String, dynamic>? _trustedSeedArtist() {
    final artistData = widget.artistData;
    if (artistData == null || artistData['isVerifiedArtist'] != true) {
      return null;
    }

    final artistId = artistData['ytid']?.toString().trim();
    final title = artistData['title']?.toString().trim();
    if (artistId == null ||
        artistId.isEmpty ||
        artistId == 'null' ||
        title == null ||
        title.isEmpty) {
      return null;
    }

    return {
      ...Map<String, dynamic>.from(artistData),
      'ytid': artistId,
      'title': title,
      'source': 'youtube-artist',
      'isArtist': true,
      'isVerifiedArtist': true,
      'catalogStatus': 'loading',
      'isCatalogComplete': false,
      'list': const [],
    };
  }

  Map<String, dynamic>? _resolvingSeedArtist() {
    final artistData = widget.artistData;
    final title = artistData?['title']?.toString().trim();
    final lookup = widget.artistId.trim();
    final seedTitle = title != null && title.isNotEmpty ? title : lookup;
    if (seedTitle.isEmpty || seedTitle == 'null') return null;

    final seedId = artistData?['ytid']?.toString().trim();
    return {
      if (artistData != null) ...Map<String, dynamic>.from(artistData),
      'ytid': seedId != null && seedId.isNotEmpty ? seedId : lookup,
      'title': seedTitle,
      'source': 'youtube-artist',
      'isArtist': true,
      'catalogStatus': 'loading',
      'isCatalogComplete': false,
      'list': const [],
    };
  }

  void _finishFullCatalogInBackground(
    Future<Map?> fullCatalogFuture,
    Map seedArtist, {
    required bool showNotFoundOnNull,
  }) {
    final seedCount = (seedArtist['list'] as List?)?.length ?? 0;
    final startsAsLoading = seedArtist['catalogStatus'] == 'loading';
    final startRevision = _artistRevision;

    if (startsAsLoading) {
      unawaited(
        Future<void>.delayed(_completeArtistLoadTimeout).then((_) {
          if (!mounted ||
              _resolvedArtist != null ||
              _artistRevision != startRevision) {
            return;
          }

          setState(() {
            _resolvedArtist = {
              ...seedArtist,
              'catalogStatus': showNotFoundOnNull ? 'notFound' : 'failed',
              'isCatalogComplete': false,
              'list': List<dynamic>.from(
                seedArtist['list'] as List? ?? const [],
              ),
            };
            _artistNotFound = showNotFoundOnNull;
            _artistRevision++;
          });
        }),
      );
    }

    unawaited(
      fullCatalogFuture
          .then((artist) {
            if (!mounted) return;
            if (artist == null) {
              if (showNotFoundOnNull) {
                setState(() {
                  _artistNotFound = true;
                  _resolvedArtist = null;
                  _artistRevision++;
                });
                _logNotFoundIfNeeded(null);
              }
              return;
            }

            final fullCount = (artist['list'] as List?)?.length ?? 0;
            final isComplete =
                artist['isCatalogComplete'] == true ||
                artist['catalogStatus'] == 'complete';
            if (!isComplete && fullCount <= seedCount) return;

            setState(() {
              _artistNotFound = false;
              _resolvedArtist = artist;
              _artistRevision++;
            });
          })
          .catchError((Object error, StackTrace stackTrace) {
            logger.log(
              'ArtistPage full catalog background load failed: '
              'lookup=${widget.artistId}',
              error: error,
              stackTrace: stackTrace,
            );
            if (!mounted || !showNotFoundOnNull) return;
            setState(() {
              _artistNotFound = true;
              _resolvedArtist = null;
              _artistRevision++;
            });
          }),
    );
  }

  void _logNotFoundIfNeeded(
    Map? artist, {
    String reason = 'no official artist',
  }) {
    if (artist == null) {
      final artistData = widget.artistData;
      logger.log(
        'ArtistPage Not found: lookup=${widget.artistId}; '
        'sourceSongId=${artistData?['sourceSongId']}; '
        'preferredName=${artistData?['title']}; reason=$reason',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map?>(
      future: _artistFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(),
            body: SizedBox(
              height: MediaQuery.sizeOf(context).height - 100,
              child: const Spinner(),
            ),
          );
        }

        if (_artistNotFound) {
          return _buildNotFoundPage();
        }

        final artist = _resolvedArtist ?? snapshot.data;
        if (artist == null) {
          return _buildNotFoundPage();
        }

        return PlaylistPage(
          key: ValueKey(
            'artist_${artist['ytid']}_${artist['catalogStatus']}_'
            '${(artist['list'] as List?)?.length ?? 0}_$_artistRevision',
          ),
          playlistId: artist['ytid']?.toString() ?? widget.artistId,
          playlistData: artist,
          cubeIcon: FluentIcons.person_24_filled,
          isArtist: true,
        );
      },
    );
  }

  Widget _buildNotFoundPage() {
    return Scaffold(
      appBar: AppBar(),
      body: const CustomScrollView(
        slivers: [
          EmptyPlaylistState(
            icon: FluentIcons.person_24_filled,
            message: 'Not found',
          ),
          SliverMiniPlayerBottomSpace(),
        ],
      ),
    );
  }
}
