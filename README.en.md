<p align="center">
  <img width="180" src="docs/images/EasySub-AppIcon.png" alt="EasySub app icon">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/umlearn/EasySub/actions/workflows/ci.yml">
    <img src="https://github.com/umlearn/EasySub/actions/workflows/ci.yml/badge.svg" alt="Build and test">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg" alt="macOS">
  <img src="https://img.shields.io/badge/requirements-macOS%2014%2B-ff69b4.svg" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-F05138.svg" alt="Swift 6">
  <a href="LICENSE.md">
    <img src="https://img.shields.io/badge/license-BSD--3--Clause-blue.svg" alt="BSD-3-Clause">
  </a>
  <a href="https://easysub.umlearn.tech/">
    <img src="https://img.shields.io/badge/website-EasySub-1687ff.svg" alt="EasySub website">
  </a>
</p>

## EasySub

EasySub is a native subtitle downloader for macOS. Drop videos or folders into the window and it searches multiple subtitle providers in parallel, automatically selects suitable subtitles based on title, year, season and episode, language, and provider confidence, then saves them alongside the videos.

Built with **Swift 6 + SwiftUI**, EasySub supports both Apple Silicon and Intel Macs and has no third-party runtime dependencies.

<p align="center">
  <img width="960" src="docs/images/EasySub-Screenshot.png" alt="EasySub main window">
</p>

## ✨ Features

- Drop videos or folders for recursive scanning, filtering, and deduplication
- Prefer ASS, prefer SRT, or download both formats
- Query OpenSubtitles, Xunlei, ASSRT, and Shooter in parallel, automatically trying another provider when one fails
- Three-tier subtitle language preferences with automatic fallback; manual search still shows all languages
- Detect movie years, TV seasons and episodes, and subtitle languages to reduce mismatches
- Preview subtitle candidates and choose one manually before downloading
- Preserve existing subtitles by default, with optional atomic replacement
- Retry failed tasks, cancel downloads, reveal files in Finder, and receive completion notifications
- Switch independently between Simplified Chinese and English, regardless of the system language
- Native support for both light and dark macOS appearances

Supported video formats include MKV, MOV, MP4, M4V, RMVB, AVI, MPEG, MPG, TS, M2TS, and WebM.

## 🚀 Installation

### Download a prebuilt release

Download the latest version from [GitHub Releases](https://github.com/umlearn/EasySub/releases/latest).

Current EasySub releases are not signed or notarized with an Apple Developer ID. When you open the app for the first time, macOS may say that it cannot verify the developer. In Finder, right-click EasySub and choose **Open**. If it is still blocked, go to **System Settings → Privacy & Security** and confirm that you want to open the app.

Only download EasySub from this project's official GitHub Releases page.

### Build from source

Building requires macOS 14 or later and Xcode 16 or later.

```sh
git clone https://github.com/umlearn/EasySub.git
cd EasySub
open EasySub.xcodeproj
```

Select the `EasySub` scheme in Xcode and run it, or build a Release version from Terminal:

```sh
xcodebuild -project EasySub.xcodeproj -scheme EasySub \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

The app will be generated at `build/Build/Products/Release/EasySub.app`. Local builds are unsigned as well.

## 🕹 Usage

1. Drop videos or folders into EasySub, or press `⌘O` to choose files.
2. Select **Prefer ASS**, **Prefer SRT**, or **Both formats**.
3. Click **Download Pending**, or press `⌘Return`.
4. Completed subtitles will appear in the corresponding video folders.

Xunlei and ASSRT are enabled by default. ASSRT only participates in searches after a token has been entered under **Settings → Subtitle Providers**. OpenSubtitles is disabled by default and requires an API key. Shooter identifies videos using file fingerprints and can help with some older releases, but its current match rate is lower, so it is disabled by default.

If automatic matching is not reliable enough, right-click an individual video and choose **Search Subtitles Manually** to review candidates before downloading.

## 📚 Documentation

- [Subtitle providers](docs/providers.html): configuration, verification status, privacy policies, and known limitations for each provider
- [Localization guide](docs/localization.html): improve an existing translation or add a new language

The project website is a static site in `docs/`; it requires neither Node nor a separate deployment workflow. To publish it, open the GitHub repository's **Settings → Pages**, select **Deploy from a branch**, then choose the default branch and the `/docs` directory.

## 🧑‍💻 Development

The core logic is maintained as an independent Swift Package, so its tests require neither live network access nor user videos:

```sh
swift test
```

Key directories:

- `Sources/EasySubApp`: SwiftUI interface, settings, notifications, and localization
- `Sources/EasySubCore`: scanning, matching, downloading, file writing, and multi-provider aggregation
- `Tests/EasySubCoreTests`: Swift Testing tests and network test doubles
- `Scripts/generate_project.py`: generates the reproducible Xcode project configuration

After adding or removing Swift files, run:

```sh
python3 Scripts/generate_project.py
```

## System requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac
- Xcode 16 or later (only required for building from source)

## Acknowledgements

Thanks to everyone who has contributed code, feedback, and ideas to EasySub, as well as [Shooter.cn](https://www.shooter.cn), [FileLister](https://github.com/dwkns/FileLister), and [ShooterSubPyDownloader](https://github.com/magic282/ShooterSubPyDownloader).

## License

EasySub is licensed under the [BSD 3-Clause License](LICENSE.md).
