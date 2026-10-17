# YouTube search and playback investigation — 2026-10-17

Base: upstream `master` at `6cd66ec4` (Musify 10.5.3+185).
Branch: `codex/youtube-search-playback`.

## Report and findings

The supplied October 13 log contains two failures: `int.parse('Streamed')`
in search date parsing, and repeated `(0) Source error` while loading audio.
The user clarified that playback currently fails for every song with the
Musify proxy option disabled, while search currently works.

### Search: confirmed parser defect

The vendored `youtube_explode_dart` 3.1.0 only removed the `Streamed` prefix
when a date had four space-separated words. `Streamed 3y ago` has three,
so it attempted to parse `Streamed` as an integer. An exception in the
mapping discarded the whole search page, including otherwise valid videos.
The same conversion is used for subsequent pages.

The fix accepts long/abbreviated English relative dates, optional
`Streamed`/`Premiered` prefixes, and whitespace variations. Unknown or
out-of-range dates return null, preserving the result and its other metadata.
Months and years retain the existing 30/365-day approximation.

Reference: https://github.com/Hexer10/youtube_explode_dart/issues/392

### Playback: Android local proxy is the leading hypothesis

Upstream commit `9ddeeb113a5c022660a698c4ced9e4683a1b72a9` enables Android
cleartext traffic. Its related issue contains the native cause
`Cleartext HTTP traffic to 127.0.0.1 not permitted` followed by the same
generic `(0) Source error`. Other users reported working playback after
installing the upstream test build, though some still reported failures.

`just_audio` uses a local HTTP proxy when custom playback headers are supplied.
This is independent of Musify's optional external proxy setting. Version
10.5.3 added playback headers but its release predates this manifest change.
The synchronized upstream base already includes the manifest fix and matching
YouTube client/playback headers. No additional speculative client changes
were applied.

Reference: https://github.com/gokadzev/Musify/issues/983

This is not confirmed as the cause on the user's device: the supplied Dart
stack lacks the underlying Android exception. Device playback must be tested.

## Validation and limitations

- The original parser reproduces the `Streamed 3y ago` exception.
- The patched parser/search suite covers 33 cases, including both search pages
  with valid, abbreviated, and unrecognized date metadata.
- Diagnostic tests cover status logging without URL queries/cookies, bounded
  playback probes with the resolving client's headers, and skipping local files.
- Analysis of the changed vendored library files passes.
- A real direct extraction attempt with both VISIONOS and ANDROID received
  HTTP 429 on the watch page, before the player API or audio CDN. This establishes
  rate limiting in the test environment, not a CDN 403 on the user's phone.
- Local Flutter is 3.47.4; upstream requires ^3.47.6. No local SDK upgrade or
  Android build was performed. The workflow selects the version from pubspec.

## Debug build and reproduction

The manual `debug.yml` workflow analyzes and tests the app and the isolated
date-parser suite, builds a universal debug APK, uploads it with a SHA-256
checksum, and publishes a pre-release only in `elias001011/Musify`.
The Android debug package is `com.gokadzev.musify.debug`, installed separately.

Debug-only diagnostics log HTTP status/host for the direct YouTube client.
When an online audio source fails initially, a separate request probes the
same CDN URL and headers with `Range: bytes=0-1023` and a five-second timeout.
It cancels the response immediately and does not alter playback retries.
The new diagnostic messages omit signed URLs and authentication headers.

On device: leave Musify proxy disabled, search for a song, then play it. Try
another song and skipping to the next track. If playback still fails, copy
the app logs, including `YouTube HTTP` and `Playback probe` entries. HTTP
403/429 points to rejection/rate limiting; a successful CDN probe with a
player error instead calls for native Android logs/local player investigation.

For a separate CLI check, from `packages/youtube_explode_dart` run:

```sh
dart pub get
dart run tool/diagnose_playback.dart jNQXAC9IVRw
```

This checks manifest extraction and receipt of an audio chunk with matching
client headers. It does not exercise Android's local player or proxy.
