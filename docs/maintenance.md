# Maintenance

When GitHub Actions is available:

1. `Sync Pre-Release` is manual-only and can be started when you want a new
   pre-release build.
2. It reads the latest commit from `gokadzev/Musify` and compares it with the
   latest `pre-release` release tag.
3. If that pre-release already exists, it exits without changes.
4. If the pre-release does not exist yet, it merges the latest upstream commit
   into `pre-release` and pushes that branch to this fork.
5. It runs `update.sh`, `flutter pub get`, and `flutter analyze`.
6. It builds installable Android APKs with a unique build number for the run.
7. It publishes a new GitHub pre-release with the APKs attached.

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

Then create a pre-release:

```bash
gh workflow run pre_release.yml --ref pre-release
```
