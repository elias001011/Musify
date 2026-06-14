import 'package:test/test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  YoutubeExplode? yt;
  setUp(() {
    yt = YoutubeExplode();
  });

  tearDown(() {
    yt?.close();
  });

  test('Resolve the canonical artist channel', () async {
    final artists = await yt!.music.searchArtists('Michael Jackson');
    expect(artists, isNotEmpty);
    // The first result is the canonical artist channel.
    expect(artists.first.id, startsWith('UC'));
    expect(artists.first.name.toLowerCase(), contains('michael jackson'));
  });

  test('Fetch the full artist discography', () async {
    final artists = await yt!.music.searchArtists('Michael Jackson');
    final releases = await yt!.music.getArtistReleases(artists.first.id);
    expect(releases, isNotEmpty);
    // The full album grid is expanded, so older albums are included.
    expect(
      releases.any((r) => r.title.toUpperCase() == 'XSCAPE'),
      isTrue,
      reason: 'XSCAPE (2014) should be present in the discography',
    );
  });

  test('Fetch tracks of an album as playable videos', () async {
    final artists = await yt!.music.searchArtists('Michael Jackson');
    final releases = await yt!.music.getArtistReleases(artists.first.id);
    final xscape = releases.firstWhere(
      (r) => r.title.toUpperCase() == 'XSCAPE',
    );

    final tracks = await yt!.music.getAlbumTracks(
      xscape.id,
      author: 'Michael Jackson',
      channelId: artists.first.id,
    );
    expect(tracks, isNotEmpty);
    expect(tracks.every((t) => t.id.value.isNotEmpty), isTrue);
    expect(
      tracks.any((t) => t.title.toLowerCase().contains('love never felt')),
      isTrue,
    );
  });
}
