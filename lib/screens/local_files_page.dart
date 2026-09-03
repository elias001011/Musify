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
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/constants/app_constants.dart';
import 'package:musify/extensions/l10n.dart';
import 'package:musify/main.dart' show audioHandler;
import 'package:musify/services/local_files_service.dart';
import 'package:musify/utilities/flutter_toast.dart';
import 'package:musify/widgets/confirmation_dialog.dart';
import 'package:musify/widgets/custom_search_bar.dart';
import 'package:musify/widgets/mini_player_bottom_space.dart';
import 'package:musify/widgets/song_bar.dart';

class LocalFilesPage extends StatefulWidget {
  const LocalFilesPage({super.key});

  @override
  State<LocalFilesPage> createState() => _LocalFilesPageState();
}

class _LocalFilesPageState extends State<LocalFilesPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _importFiles() async {
    final result = await localFilesService.pickAndImport();
    if (!mounted || result == null) return;

    final message = result.imported > 0
        ? context.l10n!.localFilesImported(result.imported)
        : result.skipped > 0
        ? context.l10n!.localFilesAlreadyImported
        : context.l10n!.localFilesImportFailed;
    showToast(context, message);
  }

  List<Map<String, dynamic>> _visibleSongs(List<Map<String, dynamic>> songs) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return songs;
    return songs.where((song) {
      final title = song['title']?.toString().toLowerCase() ?? '';
      final artist = song['artist']?.toString().toLowerCase() ?? '';
      final album = song['album']?.toString().toLowerCase() ?? '';
      return title.contains(query) ||
          artist.contains(query) ||
          album.contains(query);
    }).toList();
  }

  Future<void> _playFrom(List<Map<String, dynamic>> songs, int index) async {
    await audioHandler.addPlaylistToQueue(
      songs.cast<Map>(),
      replace: true,
      startIndex: index,
    );
  }

  void _confirmRemove(Map<String, dynamic> song) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        confirmationMessage: context.l10n!.removeLocalFileQuestion,
        submitMessage: context.l10n!.delete,
        isDangerous: true,
        onCancel: () => Navigator.of(dialogContext).pop(),
        onSubmit: () {
          Navigator.of(dialogContext).pop();
          unawaited(localFilesService.remove(song));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n!.localFiles),
        actions: [
          IconButton(
            onPressed: localFilesService.refreshIndex,
            tooltip: context.l10n!.refreshLocalFiles,
            icon: const Icon(FluentIcons.arrow_sync_24_regular),
          ),
          IconButton(
            onPressed: _importFiles,
            tooltip: context.l10n!.importLocalFiles,
            icon: const Icon(FluentIcons.add_24_regular),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          localFilesService.songs,
          localFilesService.isBusy,
        ]),
        builder: (context, _) {
          final allSongs = localFilesService.songs.value;
          final visibleSongs = _visibleSongs(allSongs);
          return Stack(
            children: [
              if (allSongs.isEmpty)
                _EmptyLocalLibrary(onImport: _importFiles)
              else
                CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: commonSingleChildScrollViewPadding,
                      sliver: SliverToBoxAdapter(
                        child: CustomSearchBar(
                          onSubmitted: (_) {},
                          onChanged: (value) => setState(() => _query = value),
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          labelText: context.l10n!.searchLocalFiles,
                        ),
                      ),
                    ),
                    if (visibleSongs.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Text(context.l10n!.noLocalFilesFound),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: commonSingleChildScrollViewPadding,
                        sliver: SliverList.separated(
                          itemCount: visibleSongs.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final song = visibleSongs[index];
                            return SongBar(
                              song,
                              false,
                              showMusicDuration: true,
                              onPlay: () =>
                                  unawaited(_playFrom(visibleSongs, index)),
                              onRemove: () => _confirmRemove(song),
                            );
                          },
                        ),
                      ),
                    const SliverMiniPlayerBottomSpace(),
                  ],
                ),
              if (localFilesService.isBusy.value)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyLocalLibrary extends StatelessWidget {
  const _EmptyLocalLibrary({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.music_note_2_24_filled,
              size: 56,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n!.noLocalFiles,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n!.noLocalFilesDescription,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(FluentIcons.folder_open_24_regular),
              label: Text(context.l10n!.importLocalFiles),
            ),
          ],
        ),
      ),
    );
  }
}
