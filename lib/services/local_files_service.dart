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

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/main.dart' show logger;
import 'package:musify/services/common_services.dart' show userRecentlyPlayed;
import 'package:path_provider/path_provider.dart';

const supportedLocalAudioExtensions = <String>{
  '.aac',
  '.aif',
  '.aifc',
  '.aiff',
  '.ape',
  '.flac',
  '.m4a',
  '.mp3',
  '.mp4',
  '.ogg',
  '.opus',
  '.wav',
};

class LocalImportResult {
  const LocalImportResult({
    required this.imported,
    required this.skipped,
    required this.failed,
  });

  final int imported;
  final int skipped;
  final int failed;
}

class LocalFilesService {
  factory LocalFilesService() => _instance;

  LocalFilesService._();

  static final LocalFilesService _instance = LocalFilesService._();

  final ValueNotifier<bool> isBusy = ValueNotifier(false);
  final ValueNotifier<List<Map<String, dynamic>>> songs = ValueNotifier(
    _readStoredSongs(),
  );

  static List<Map<String, dynamic>> _readStoredSongs() {
    final raw = Hive.box('user').get('localSongs', defaultValue: const []);
    if (raw is! List) return [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<Directory> _audioDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/local_audio');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _artworkDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/local_audio_artwork');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<LocalImportResult?> pickAndImport() async {
    if (isBusy.value) return null;

    final selection = await FilePicker.pickFiles(type: FileType.audio);
    if (selection.isEmpty) return null;

    isBusy.value = true;
    var imported = 0;
    var skipped = 0;
    var failed = 0;

    try {
      final audioDirectory = await _audioDirectory();
      final artworkDirectory = await _artworkDirectory();
      final updatedSongs = List<Map<String, dynamic>>.from(songs.value);

      for (var index = 0; index < selection.length; index++) {
        final pickedFile = selection[index];
        final sourcePath = pickedFile.path;
        final extension = _extensionOf(pickedFile.name);

        if (sourcePath == null ||
            !supportedLocalAudioExtensions.contains(extension)) {
          failed++;
          continue;
        }

        final source = File(sourcePath);
        try {
          if (!await source.exists()) {
            failed++;
            continue;
          }

          final sourceSize = await source.length();
          final fingerprint = (await sha256.bind(source.openRead()).first)
              .toString();
          final isDuplicate = updatedSongs.any(
            (song) => song['fingerprint'] == fingerprint,
          );
          if (isDuplicate) {
            skipped++;
            continue;
          }

          final importId =
              '${DateTime.now().microsecondsSinceEpoch}_${index.toString().padLeft(2, '0')}';
          final safeName = sanitizeLocalFileName(
            _fileNameWithoutExtension(pickedFile.name),
          );
          final destination = File(
            '${audioDirectory.path}/${importId}_$safeName$extension',
          );
          await source.copy(destination.path);

          try {
            final parsed = await Isolate.run(
              () => readLocalAudioMetadata(destination.path),
            );
            File? artwork;
            try {
              artwork = await _writeArtwork(
                parsed.remove('artworkBytes') as Uint8List?,
                parsed.remove('artworkMime')?.toString(),
                artworkDirectory,
                importId,
              );
            } catch (error, stackTrace) {
              logger.log(
                'Failed to save local audio artwork',
                error: error,
                stackTrace: stackTrace,
              );
            }
            final song = <String, dynamic>{
              'id': 'local:$importId',
              'ytid': 'local:$importId',
              'title':
                  _nonEmpty(parsed['title']) ??
                  _fileNameWithoutExtension(pickedFile.name),
              'artist': _nonEmpty(parsed['artist']) ?? '',
              'album': _nonEmpty(parsed['album']) ?? '',
              'duration': parsed['duration'],
              'audioPath': destination.path,
              'artworkPath': artwork?.path,
              'artWorkPath': artwork?.path,
              'highResImage': '',
              'lowResImage': '',
              'sourceName': pickedFile.name,
              'fileSize': sourceSize,
              'fingerprint': fingerprint,
              'dateAdded': DateTime.now().toIso8601String(),
              'isLocal': true,
              'isLive': false,
            }..removeWhere((_, value) => value == null);
            updatedSongs.add(song);
            imported++;
          } catch (error, stackTrace) {
            await destination.delete().catchError((_) => destination);
            logger.log(
              'Failed to index local audio file',
              error: error,
              stackTrace: stackTrace,
            );
            failed++;
          }
        } catch (error, stackTrace) {
          logger.log(
            'Failed to import local audio file',
            error: error,
            stackTrace: stackTrace,
          );
          failed++;
        }
      }

      updatedSongs.sort(_compareSongs);
      songs.value = updatedSongs;
      await _persist();
      return LocalImportResult(
        imported: imported,
        skipped: skipped,
        failed: failed,
      );
    } finally {
      isBusy.value = false;
    }
  }

  Future<void> refreshIndex() async {
    if (isBusy.value) return;
    isBusy.value = true;
    try {
      final available = <Map<String, dynamic>>[];
      for (final song in songs.value) {
        final path = song['audioPath']?.toString();
        if (path != null && path.isNotEmpty && await File(path).exists()) {
          available.add(Map<String, dynamic>.from(song));
        }
      }
      available.sort(_compareSongs);
      songs.value = available;
      await _persist();
    } finally {
      isBusy.value = false;
    }
  }

  Future<void> remove(Map song) async {
    final id = song['ytid']?.toString();
    if (id == null) return;

    final remaining = songs.value
        .where((candidate) => candidate['ytid']?.toString() != id)
        .map(Map<String, dynamic>.from)
        .toList();

    for (final key in ['audioPath', 'artworkPath']) {
      final path = song[key]?.toString();
      if (path == null || path.isEmpty) continue;
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (error, stackTrace) {
          logger.log(
            'Failed to delete imported local file',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    songs.value = remaining;
    final recentSongs = List<Map>.from(
      userRecentlyPlayed.value.whereType<Map>(),
    )..removeWhere((song) => song['ytid']?.toString() == id);
    userRecentlyPlayed.value = recentSongs;
    await Future.wait([
      _persist(),
      Hive.box('user').put('recentlyPlayedSongs', recentSongs),
    ]);
  }

  Future<File?> _writeArtwork(
    Uint8List? bytes,
    String? mime,
    Directory directory,
    String importId,
  ) async {
    if (bytes == null || bytes.isEmpty) return null;
    final extension = switch (mime?.toLowerCase()) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      _ => '.jpg',
    };
    return File('${directory.path}/$importId$extension').writeAsBytes(bytes);
  }

  Future<void> _persist() => Hive.box('user')
      .put('localSongs', songs.value.map(Map<String, dynamic>.from).toList());
}

final localFilesService = LocalFilesService();

Map<String, dynamic> readLocalAudioMetadata(String path) {
  try {
    final metadata = readMetadata(File(path), getImage: true);
    final preferredArtwork = metadata.pictures.where(
      (picture) => picture.pictureType == PictureType.coverFront,
    );
    final artwork = preferredArtwork.isNotEmpty
        ? preferredArtwork.first
        : metadata.pictures.firstOrNull;
    return {
      'title': metadata.title,
      'artist': metadata.artist,
      'album': metadata.album,
      'duration': metadata.duration?.inSeconds,
      'artworkBytes': artwork?.bytes,
      'artworkMime': artwork?.mimetype,
    };
  } catch (_) {
    return {};
  }
}

String sanitizeLocalFileName(String value) {
  final sanitized = value
      .replaceAll(RegExp('[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^[_\.]+|[_\.]+$'), '');
  return sanitized.isEmpty ? 'audio' : sanitized;
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

String _fileNameWithoutExtension(String name) {
  final normalized = name.replaceAll('\\', '/').split('/').last;
  final dot = normalized.lastIndexOf('.');
  return dot <= 0 ? normalized : normalized.substring(0, dot);
}

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _compareSongs(Map<String, dynamic> a, Map<String, dynamic> b) {
  final artistComparison = (a['artist']?.toString() ?? '')
      .toLowerCase()
      .compareTo((b['artist']?.toString() ?? '').toLowerCase());
  if (artistComparison != 0) return artistComparison;
  return (a['title']?.toString() ?? '').toLowerCase().compareTo(
    (b['title']?.toString() ?? '').toLowerCase(),
  );
}
