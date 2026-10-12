<h1 align="center">
  <br>
  <img src="Configuration/branding/twanotch-icon.svg" alt="TwaNotch" width="150">
  <br>
  TwaNotch
  <br>
</h1>

<p align="center">A personal build of <a href="https://github.com/TheBoredTeam/boring.notch">boring.notch</a> that turns the MacBook notch, or the top of any display on a Mac without one, into a music, calendar, shelf and HUD hub.</p>

## What it does

- Now Playing live activity with controls and visualizer (Apple Music, Spotify, YouTube Music, any Now Playing source).
- Calendar and Reminders in the notch.
- Mirror (camera preview).
- Charging indicator and battery percentage.
- File shelf with AirDrop and quick share.
- System HUD replacement for volume, brightness and keyboard backlight.
- English and Vietnamese interface.

## How it differs from boring.notch

- Own bundle identifier (`com.twan.twanotch`), name and icon, so it installs side by side with Boring Notch and keeps separate settings and permissions.
- Updates come from this repository's own releases through Sparkle, signed with its own key, so boring.notch releases can never replace this build.
- Hardware-aware: features the Mac cannot drive (battery, display brightness on external monitors, keyboard backlight, mirror without a camera) are hidden, and their keys go back to macOS. On a Mac mini this hides most of them. Toggle it in Settings > General > Hardware.
- Settings redesigned in the style of macOS System Settings.
- Vietnamese translation, with a language picker in Settings > General > Language (System default, English, Tiếng Việt). Changing it restarts the app.

## Install

```bash
brew install --cask twan-nguyen/tap/twanotch
```

If Homebrew refuses the tap as untrusted, trust it once with `brew trust --tap twan-nguyen/tap` and run the install again.

The app is signed with a self-signed certificate and is not notarized. The cask removes the download quarantine after installing, so Gatekeeper does not block it. If you download the zip from Releases yourself, clear it by hand:

```bash
xattr -dr com.apple.quarantine /Applications/TwaNotch.app
```

To update, use **Check for Updates…** in the menu bar icon or in Settings > About. Sparkle downloads the new version, replaces the app and relaunches it. `brew upgrade` leaves the app alone because the cask is marked `auto_updates`.

## Music sources

Choose the source in Settings > Media > Music Source.

- **Now Playing** (recommended) reads whatever macOS shows in Control Center, so it works with Chrome and Safari tabs, YouTube Music installed as a Chrome web app, Spotify and Apple Music.
- **YouTube Music** only works with the third-party desktop app [pear-desktop](https://github.com/pear-devs/pear-desktop) and its API server enabled. It does not detect YouTube Music in a browser or as a Chrome web app.
- **Apple Music** and **Spotify** talk to those apps directly through AppleScript.

## Building from source

Requirements: macOS 15.6 or later and Xcode 26 or later.

```bash
git clone https://github.com/twan-nguyen/twanotch.git
cd twanotch
open boringNotch.xcodeproj
```

Select the `boringNotch` scheme and press `Cmd + R` to run a debug build.

To build Release and install it, run:

```bash
scripts/install.sh
```

The script builds into `build/DerivedData`, signs the app, quits the running TwaNotch, replaces `/Applications/TwaNotch.app` and launches the new copy.

### Signing

Releases and local installs are signed with the same self-signed certificate, "TwaNotch Self-Signed". No Apple Developer account is involved. Because the identity stays the same from one build to the next, macOS keeps the Accessibility permission (needed for the HUD replacement) across updates and rebuilds.

- The identity lives in its own keychain, `~/Library/Keychains/twanotch-signing.keychain-db`. Its random password is stored in the login keychain under `twanotch-signing-keychain`, so `scripts/install.sh` can unlock it without prompting. To recreate it on another Mac from a `.p12` backup, run `scripts/setup-signing-keychain.sh TwaNotch-Self-Signed.p12`.
- Without that keychain, `scripts/install.sh` installs the ad-hoc build Xcode produced. macOS then treats every rebuild as a new app and asks for Accessibility again.
- `scripts/sign-app.sh` re-signs everything inside the bundle (Sparkle, the XPC helper and the frameworks) and keeps each item's entitlements.
- The app is not signed by an Apple team, and it links `MediaRemoteAdapter.framework`, so `boringNotch.entitlements` includes `com.apple.security.cs.disable-library-validation`. Without it the app crashes at launch with "different Team IDs".

## Releasing

Push a version tag:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The [Release workflow](.github/workflows/release.yml) builds a universal Release, signs it, zips it, writes a Sparkle `appcast.xml` signed with the EdDSA key, publishes both on a GitHub release, and updates `Casks/twanotch.rb` in [twan-nguyen/homebrew-tap](https://github.com/twan-nguyen/homebrew-tap). The version comes from the tag, and the build number is the commit count, so it always grows. The app reads its feed from `releases/latest/download/appcast.xml`.

The workflow needs these repository secrets:

| Secret | Contents |
|---|---|
| `SIGNING_CERT_P12_BASE64` | The signing identity as a base64 `.p12` |
| `SIGNING_CERT_PASSWORD` | Password of that `.p12` |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (also in the login keychain, account `twanotch`) |
| `TAP_DEPLOY_KEY` | Private SSH key of a write deploy key on the tap repository |

Back up the signing identity and the Sparkle key. Installed copies only accept updates signed with that Sparkle key, and keep their permissions only while the certificate stays the same.

## Translations

UI strings live in `boringNotch/Localizable.xcstrings`. A command-line build does not add new strings to the catalog, so after adding UI text either build once in Xcode or run:

```bash
xcodebuild -exportLocalizations -project boringNotch.xcodeproj -localizationPath /tmp/twanotch-loc -exportLanguage vi
```

Then add the `vi` translation for the new keys in the catalog.

Some text is still English in Vietnamese mode: system permission prompts, onboarding step descriptions and the names of HUD styles and music sources.

## Icon

The app icon source is [Configuration/branding/twanotch-icon.svg](Configuration/branding/twanotch-icon.svg). After editing it, regenerate the PNGs in `boringNotch/Assets.xcassets/AppIcon.appiconset` (for example with `rsvg-convert`).

## Credits and license

TwaNotch is based on [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam and its contributors, and is distributed under the same [GPL-3.0 license](LICENSE). It also builds on [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) and [NotchDrop](https://github.com/Lakr233/NotchDrop); see [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for all attributions.
