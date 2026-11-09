# Releasing

Same flow as sharemask. `main` is protected: changes land through a pull request (no review
required), so do the version bump on a branch and merge it before tagging.

0. The app icon is rendered by `packaging/make-icon.swift` (`swiftc -O -o /tmp/icon packaging/make-icon.swift && /tmp/icon <dir>` → `iconutil -c icns <dir>/AppIcon.iconset`); re-run it only if the icon changes.
1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. `make release` → `build/hearsay-<version>.zip` and its sha256.
3. `gh release create v<version> build/hearsay-<version>.zip --title "hearsay <version>" --notes "..."`
   (the repo must be public for Homebrew to download the asset without auth).
4. Update `version` and `sha256` in `packaging/hearsay.rb`, copy it to the tap repo
   `Larry8668/homebrew-hearsay` as `Casks/hearsay.rb`, commit, push.
   First time: `gh repo create Larry8668/homebrew-hearsay --public` with just `Casks/` and a README.
5. Users: `brew tap Larry8668/hearsay && brew trust Larry8668/hearsay && brew install --cask hearsay`;
   upgrades via `brew upgrade --cask hearsay`. The cask's postflight strips the quarantine attribute.

The signing certificate must stay the same across releases (it is what keeps the Microphone and
System Audio grants); `make identity` creates `hearsay-dev` once per machine, so build releases on
the same machine or import the exported p12 elsewhere.
