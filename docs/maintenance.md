# Desktop Port Maintenance

This repository is intentionally maintained as a downstream desktop port of
`gokadzev/Musify`.

## Automated Flow

When GitHub Actions is available:

1. `Sync Upstream Release` runs every six hours and can also be started manually.
2. It reads the latest upstream release tag from `gokadzev/Musify`.
3. If this repository already has a matching `desktop-v<version>` release, it
   exits without changes.
4. If the desktop release does not exist, it fetches upstream tags and merges the
   upstream release tag into `master`.
5. It runs `update.sh`, `flutter pub get`, and `flutter analyze`.
6. If the sync is clean, it pushes `master` and dispatches `Build Desktop Release`.
7. `Build Desktop Release` builds Linux and Windows packages and publishes a
   stable GitHub release.

If the upstream merge or analysis fails, the sync workflow opens an issue with a
link to the failed run.

## Manual Sync

Use this when Actions is unavailable or a conflict needs local attention:

```bash
git checkout master
git fetch upstream --tags --prune
git merge --no-edit refs/tags/<upstream-version>
./update.sh
flutter pub get
flutter analyze
git push origin master
```

Then create a desktop release:

```bash
gh workflow run desktop_release.yml --ref master -f tag=desktop-v<version> -f prerelease=false
```

If Actions is still blocked, build Linux locally and use a Windows machine for
the Windows assets, then upload the files manually:

```bash
flutter build linux --release
.github/scripts/package_linux_desktop.sh
gh release create desktop-v<version> build/desktop-artifacts/* --latest
```

## Remotes

Recommended local remotes:

```bash
git remote add origin https://github.com/elias001011/Musify-Desktop-Port.git
git remote add upstream https://github.com/gokadzev/Musify.git
```

The original upstream project should remain the source of application updates.
Desktop-only changes should stay small and easy to carry forward.
