# Publishing Checklist

This project is ready to be put in a GitHub repository, but it should not be published before the owner makes the final release decisions below.

## Required Before Public Release

- ~~Choose a license and add `LICENSE`.~~ Done: Apache License 2.0, copyright AlB4k, 2026.
- Review `THIRD_PARTY_NOTICES.md` and keep third-party data out of the repository unless its license allows redistribution.
- Decide whether `local.iplist.mac` should be replaced with a reverse-DNS bundle identifier owned by the publisher.
- Decide whether the app should be notarized for distribution outside this Mac.
- Review the README text for public wording and repository name.
- Add screenshots if the repository should be understandable from the GitHub page without building the app.
- Create a fresh build with `./scripts/build-app.sh`.
- Run `./scripts/test.sh`.
- Optionally run `IPLIST_LIVE_TEST=1 ./scripts/test.sh` before a tagged release.

## Do Not Commit

- `dist/`
- `.build/`
- `DerivedData/`
- Files from `~/Library/Application Support/IPList/`
- Downloaded upstream JSON/list files unless their redistribution terms are clarified.
- Personal AmneziaVPN exports that contain private manual IP entries.

## Suggested First GitHub Steps

```sh
git add .
git commit -m "Initial IPList macOS app"
```

The local repository already uses the `main` branch. Then create an empty GitHub repository and add it as `origin`. Push only after reviewing the staged files.

## CI

The included GitHub Actions workflow runs on `macos-latest`, executes the standalone Swift test harness, and builds the app bundle. It does not run live network tests by default, so CI should be stable even when upstream list services are slow.
