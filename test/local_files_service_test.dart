import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/local_files_service.dart';

void main() {
  group('local file indexing helpers', () {
    test('sanitizes imported names without losing useful characters', () {
      expect(sanitizeLocalFileName('  My song (live)!  '), 'My_song_live');
      expect(sanitizeLocalFileName('...'), 'audio');
      expect(sanitizeLocalFileName('track-01_mix'), 'track-01_mix');
    });

    test('documents the audio formats accepted by the importer', () {
      expect(
        supportedLocalAudioExtensions,
        containsAll(<String>[
          '.mp3',
          '.m4a',
          '.flac',
          '.ogg',
          '.opus',
          '.wav',
          '.aac',
        ]),
      );
    });

    test('metadata reading gracefully falls back for untagged audio', () async {
      final directory = await Directory.systemTemp.createTemp(
        'musify_local_files_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/untagged.aac');
      await file.writeAsBytes([0, 1, 2, 3]);

      expect(readLocalAudioMetadata(file.path), isEmpty);
    });
  });
}
