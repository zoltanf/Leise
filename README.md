# Leise

Leise is a free, local-first speech-to-text app for macOS. It is a community fork of
[TypeWhisper for Mac](https://github.com/TypeWhisper/typewhisper-mac), with the commercial
licensing, supporter entitlements, purchase flows, premium gates, and plugin marketplace
removed.

Leise is not affiliated with or endorsed by the TypeWhisper project. See [FORK.md](FORK.md)
for provenance and [TRADEMARK.md](TRADEMARK.md) for the upstream trademark notice.

## Principles

- **GPL throughout** — retained features are available without product entitlements.
- **Local first** — the model picker exposes bundled local transcription engines.
- **Small extension boundary** — the SDK is an internal boundary for bundled engines;
  Leise does not load arbitrary external bundles or present a plugin marketplace.
- **Private by default** — local transcription keeps audio on the Mac.

## Included capabilities

- System-wide dictation with global hotkeys
- Local transcription models, with streaming where supported
- File and recorder transcription
- History, dictionary corrections, and target-app profiles
- Recovery from transient audio-device failures and saved failed dictations
- Configurable filler-word cleanup and spoken-punctuation handling
- Built-in terminology packs for specialized vocabulary

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- Apple Silicon is recommended for local MLX models
- 8 GB RAM minimum; 16 GB or more is recommended for larger models

## Build

```sh
git clone <your-leise-fork-url>
cd Leise
open Leise.xcodeproj
```

Select the `Leise` scheme in Xcode and build. Swift package dependencies resolve through
Xcode.

Run checks with a full Xcode installation selected:

```sh
xcodebuild test \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

swift test --package-path LeiseComponents
```

## Forking and remotes

The cloned repository keeps upstream history. A typical remote layout is:

```sh
git remote rename origin upstream
git remote add origin git@github.com:<you>/leise.git
```

Keep upstream attribution and GPL notices when redistributing modified builds. Use your own
bundle identifiers, signing team, update feed, icons, and release infrastructure.

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
