<div align="center">

# Aurora

**Everything you tweak on macOS, in one menu bar panel**

Display & screen tests · Mouse & keyboard · Finder context menu · Clipboard · Screenshots & recording · Dynamic wallpaper · Keep-awake · Audio · AI usage · External devices

[![CI](https://github.com/CaryK753/Aurora/actions/workflows/ci.yml/badge.svg)](https://github.com/CaryK753/Aurora/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/CaryK753/Aurora?label=release)](https://github.com/CaryK753/Aurora/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-26%2B-black.svg)](#requirements)

[简体中文](README.md) · [English](README.en.md)

</div>

![Overview](docs/overview.png)

## What it is

Aurora is a native macOS menu bar utility written in SwiftUI, using the Liquid Glass design of macOS 26. It gathers the things you usually do in System Settings, in a terminal, or across half a dozen tiny utilities into a single panel — one click on the menu bar icon, or **⌥⌘A**.

By default it is a floating panel that disappears when you click away. The **pin** button in the top-right corner turns it into a regular macOS window — native traffic lights in the top-left, minimizable, ⌘W closes it, and clicking elsewhere no longer dismisses it. Unpin and it goes straight back. While pinned you can also resize the window by its edges (with sensible limits), go full-screen with the green button, and the traffic lights align precisely with the interface; widen the window and module cards rearrange into two columns automatically.

Dynamic wallpaper renders on the desktop layer (above Finder's wallpaper, below desktop icons) and ignores all mouse clicks. Quitting Aurora or flipping the switch restores the system wallpaper untouched. The lock / login screen keeps showing the system wallpaper.

Three rules shaped the implementation:

- **Use the system APIs that actually exist.** No invented numbers — for example, there is no public per-process GPU API, so Aurora does not fake one.
- **Data stays on device.** Usage statistics are read from local logs; nothing is uploaded.
- **Interception is reversible.** Wheel, volume and hotkey takeovers are released the moment you flip the switch or quit the app.

## Features

| Module | What it does |
| --- | --- |
| **Overview** | CPU (per core + graph), GPU, memory breakdown, network (VPN status + speed test), disk capacity and read/write throughput, battery health and cycle count. **External devices** lists Bluetooth and USB hardware — Apple devices get their own icons and real model names, AirPods report left/right/case levels, external volumes show usage. Top processes can be sorted by CPU, GPU, memory or network |
| **Display** | Built-in brightness, DDC/CI brightness · volume · contrast for external monitors, brightness presets with smooth transitions, resolution switching, restore on launch, **⌃⌥↑/↓ global brightness**; **screen tests** cover solid colours, grey steps, gradient, colour bars, checkerboard, grid, text and dead pixels, filling every connected display |
| **Pointer** | Every attached mouse, plus a live pointer probe; cursor speed and acceleration, wheel speed and acceleration, **smooth scrolling**, **separate reversal for mouse and trackpad**, Shift-to-horizontal, modifier inversion; **button capture mapping** — hit Capture, press a single button like Mos, then pick an action; the panel pins itself while capturing so no shortcut can close it |
| **Trackpad** | Tracking speed, tap to click, two-finger secondary click, natural scrolling, zoom/rotate, swipe between pages, three-finger drag — written straight to system preferences |
| **Keyboard** | Lists every keyboard (built-in / USB / Bluetooth, battery, VID:PID); ANSI / ISO / JIS keyboard type; a **key test** window that highlights physical keys and decodes ⌃⌥⇧⌘ combinations; **clean mode** swallows all key input; repeat delay/rate and F1–F12 function-key priority |
| **Menu** | A **real custom Finder context menu** built on a FinderSync extension: copy path, open in Terminal, open with app, run command, create file — add, edit, reorder, toggle individually, effective immediately. Also manages Quick Actions, Services and Finder extensions |
| **Desktop** | Show or hide desktop icons, hide files and extensions, restart Finder. **Dynamic wallpaper**: looping video / GIF (with head-tail trimming), four auto rules — one fixed, follow Light/Dark appearance (soft cross-fade), time-of-day schedule, shuffle; four built-in **procedural dynamic scenes** (Aurora / Waves / Glow / Sunset — no disk space, recolorable); drag-and-drop library with type filters, full-screen preview, five fill modes (fill / fit / stretch / center / tile), per-display settings; bundled Apple wallpapers (including aerial videos the system has downloaded), an online sources section (Unsplash / Pixabay / Wallhaven / NASA / Coverr) and download-by-URL |
| **Clipboard** | Six record types — text, rich text, link, image, file, colour; search, filter, pinning, duplicate merging with counts, keyboard copy/paste, paste as plain text, edit and detail views; ignore rules for confidential types, apps, regex and one-shot skips; recording pauses automatically while secure input is active |
| **Screenshots** | Area, window (hover to highlight, click to capture the whole window), full screen and scrolling capture; global ⌥⌘S. The editor ships 13 tools (select/move, pen, line, arrow, rectangle, filled rectangle, ellipse, highlighter, gaussian blur, mosaic, spotlight, step counter, text), snapshot-based undo/redo, Apple device bezels with automatic model detection, and AirDrop to an iPhone or iPad for markup, then retrieve the result |
| **Recording** (Beta) | Record a whole display, a specific window, or a dragged region; system audio and microphone are muxed into one MP4 as two audio tracks — never more than one output file. Pause/resume remaps timestamps so the result has no gaps and audio stays in sync. Picture-in-picture camera bubble (rounded rectangle by default; drag to move, drag a corner to resize, right-click for shape / size / mirror / camera), mouse-click highlights and live keystrokes. Frame rate, H.265/H.264, native Retina pixels, pointer visibility; ⌥⌘R toggles recording and a draggable floating bar lets you switch sources |
| **Energy** | Keep the Mac awake from 15 minutes to 2 hours, optionally keep the display on; stop automatically under 20% battery; start at login; **remember the state** — if keep-awake was still on when you quit, the next launch restores it (optional) |
| **Audio** | Input/output device switching, volume and mute, **per-app volume** (0–150%) |
| **Storage** | Three tabs: **Clean** (disk usage, caches / logs / Xcode / simulator / Homebrew / Trash with per-item checks, **universal binary thinning** (real icons, per-item and select-all), large files, CLI tool entry points), **Apps** (installed apps by size; uninstalling also collects caches, preferences, containers and login items — all into the Trash), **Dev** (13 package-manager caches plus node_modules / target / .build artifacts). Everything goes to the Trash; `brew` / `docker` / `mole` / `ncdu` are only detected and offered as "Run in Terminal" — no third-party binaries are bundled |
| **AI usage** | Per-harness adapters: Codex (rollout logs plus real quota windows), Claude Code, opencode, WorkBuddy and more; desktop clients are detected and reported honestly. Aggregates the last 7 days, today and the 5-hour window |
| **Settings** | Language (system / Chinese / English), appearance, launch at login, module toggles, live permission checks, automatic updates, GitHub entry and reset |

## Screenshots

| Display | Pointer | Keyboard |
| --- | --- | --- |
| ![](docs/display.png) | ![](docs/pointer.png) | ![](docs/keyboard.png) |

| Clipboard | Menu | Audio |
| --- | --- | --- |
| ![](docs/clipboard.png) | ![](docs/menu.png) | ![](docs/audio.png) |

| Energy | AI usage | Settings |
| --- | --- | --- |
| ![](docs/energy.png) | ![](docs/ai.png) | ![](docs/settings.png) |

## Requirements

- **macOS 26 or later** (the panel uses `NSGlassEffectView`)
- Apple Silicon and Intel are both supported; official builds are universal

## Installation

### Download a build (recommended)

1. Grab `Aurora-<version>.zip` from [Releases](https://github.com/CaryK753/Aurora/releases/latest).
2. Unzip it and drag `Aurora.app` into **Applications**.
3. Grant the permissions you need (next section).

#### "Aurora is damaged and can't be opened"

The build is not notarised by Apple, so on a Mac with Gatekeeper enabled you may see:

> "Aurora" is damaged and can't be opened. You should move it to the Trash.

The download is **not actually corrupted** — it just carries the quarantine attribute. Clear it from Terminal:

```bash
sudo xattr -c /Applications/Aurora.app
```

Then open the app again (the first launch may still need **right-click → Open** in Finder). Adjust the path if you installed it somewhere else. If you prefer to remove only the quarantine flag and keep other extended attributes:

```bash
sudo xattr -dr com.apple.quarantine /Applications/Aurora.app
```

> The build is ad-hoc signed and not notarised — the usual trade-off for open-source projects without a paid developer account. It does not make the app less safe; building from source is equally supported, and the command above applies to local builds too.

### Build from source

Requires Xcode 26 or newer (Swift 6.2+).

```bash
git clone https://github.com/CaryK753/Aurora.git
cd Aurora
./build.sh                 # build, sign and install to /Applications/Aurora.app
```

Useful flags:

```bash
AURORA_INSTALL=0 ./build.sh release       # package only
AURORA_UNIVERSAL=1 ./build.sh release     # arm64 + x86_64
AURORA_VERSION=1.4.0 AURORA_BUILD=10 ./build.sh release
AURORA_SIGN_ID="Apple Development: ..." ./build.sh release
```

Without `AURORA_SIGN_ID`, the script uses a local developer certificate when available and falls back to ad-hoc otherwise. Signing with a stable identity avoids the classic "granted in System Settings but the app still says no" problem: TCC records grants per signature, and ad-hoc builds change their cdhash on every rebuild.

## First launch and permissions

The first launch walks you through three steps: what Aurora does, which modules to enable, and the permissions you need.

| Permission | Used for | Required |
| --- | --- | --- |
| Accessibility | Pointer interception, side buttons, simulated paste and keystrokes | Pointer module |
| Screen Recording | Screenshot actions, window previews | Screenshot features only |
| Input Monitoring | Raw buttons from external mice | External mouse macros only |
| Full Disk Access | Reading other apps' settings and local usage databases | Optional |
| Notifications | Instant alerts for new versions, finished recordings, saved screenshots and finished breaks | Optional |
| Camera | Records your camera into the video for picture-in-picture | Optional |
| Microphone | Adds a second audio track from the microphone | Optional |

Permission state is re-checked every 3 seconds and can be refreshed manually from **Settings › Permissions**. If the system says a permission is granted but Aurora disagrees, remove the old Aurora entry and add `/Applications/Aurora.app` again.

## Shortcuts and gestures

| Action | Notes |
| --- | --- |
| **⌥⌘A** | Open / close the panel (works even when the menu bar icon is hidden) |
| **⌃⌥↑ / ⌃⌥↓** | Raise or lower the main display brightness by 6% without opening the panel |
| **⌘ + drag a sidebar icon** | Reorder modules; drop outside the panel to be asked whether to disable it |
| **⌘1 – ⌘9** | Copy a pinned clipboard entry (add ⌥ to paste into the previous app) |
| **⌃⌥⌘K** | Leave keyboard clean mode |
| **⇧⌘V** | Open the mini clipboard (↑↓ to select, ⏎ to paste, ⌘1–9 to paste directly, ⌘⌫ to delete) |
| **⌥⌘S** | Area screenshot, straight into the annotation editor |
| **⌥⌘R** | Start / stop screen recording |
| **ESC** | Close the panel, exit a screen test, or cancel a button capture |
| **⌘W / ⌘M** | Close / minimize once the panel is pinned as a window |

## Automatic updates

The built-in updater reads this repository's GitHub releases:

- Checks for the latest release **every hour** by default and downloads it automatically.
- Once downloaded, Aurora asks before doing anything: confirm to replace `Aurora.app` and relaunch, or choose "Later" and update whenever you want.
- The prompt shows only the current version, package size and four highlights — HTML and Markdown in the release body are converted to plain text, so no stray tags.
- The first launch after an update opens a What's New window describing that version (read from the bundled `CHANGELOG.md`, so it works offline). Each version is shown once; reopen it any time from **Settings › About › What's New**.
- You can also run a manual check from **Settings › About**, or turn automatic updates off and keep manual checks.
- Only the app bundle is replaced. Settings, clipboard history and custom menu items live in `~/Library/Application Support/Aurora` and are never touched.
- Official builds are ad-hoc signed by CI. If you previously ran a build signed with your own developer certificate, the signature change makes macOS treat it as a different app — **re-grant Accessibility and friends once after that first update** (updates between your own fixed-identity builds are unaffected).

## Project layout

```
Sources/
├── Aurora/                      The app (SwiftUI + AppKit)
│   ├── main.swift               Entry point and CLI tools
│   ├── AppDelegate.swift        Menu bar, hotkeys, lifecycle
│   ├── PanelController.swift    Liquid Glass floating panel
│   ├── AppState.swift           Global state and service wiring
│   ├── Module.swift             Module registry
│   ├── Core/                    Service implementations
│   ├── UI/                      Panel, module views, component library
│   └── SelfTest.swift           Self-checks and diagnostics
├── AuroraFinder/                FinderSync context-menu extension (signed separately)
Modules/
└── LogitechPlugin/              Logitech HID++ device plugin (with unit tests)
Resources/                       Icons and entitlements
Tests/                           Panel, preferences, permissions and functional scripts
Tools/                           Icon generator
docs/                            Screenshots and architecture notes
```

`build.sh` does the packaging: it builds the SwiftPM targets, assembles the `.app`, compiles the Finder extension by hand with `swiftc -e _NSExtensionMain`, and signs both bundles.

## Development and testing

```bash
swift build                      # build
swift test                       # unit tests (LogitechPlugin)

Aurora --selftest                # capability overview: displays, sampling, permissions, GPU, audio, usage, menu
Aurora --scroll-test             # wheel transforms: speed / reverse / Shift-horizontal / modifiers / residuals
Aurora --clip-e2e                # clipboard end-to-end: dedupe, RTF on disk, image on disk
Aurora --keyboard-clean-test     # clean-mode interception and unlock
Aurora --device-test             # enumerate keyboards and pointing devices
Aurora --update-test             # read the latest GitHub release and compare versions, no download
Aurora --update-test --download  # also download and unpack (no prompt, no install)
```

Regression scripts live in `Tests/`: `bash Tests/Functional/run.sh`, `Tests/Panel/run.sh`, `Tests/Preferences/run.sh`, `Tests/Permissions/run.sh`.

Implementation notes are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Continuous integration

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`ci.yml`](.github/workflows/ci.yml) | push / PR | Build, unit tests, package the `.app`, verify the signature, keep the artifact for 7 days |
| [`release.yml`](.github/workflows/release.yml) | `v*` tag or manual dispatch | Build the universal binary, produce the zip and SHA-256 checksum, publish a GitHub release |

Cutting a release:

```bash
git tag v1.1.0
git push origin v1.1.0
```

## Contributing

Issues and pull requests are welcome.

- Make sure `swift build` and `swift test` pass before opening a PR.
- When adding a module, add both Chinese and English strings (`Localization.swift` / `ModuleTranslations.swift`) and update the feature table here.
- For changes touching system APIs, describe how you verified them and any known limitations.

## License

Released under the [MIT License](LICENSE).

## Acknowledgements

Interactions and feature sets were inspired by these projects — ideas and configuration semantics only, no source code copied:

[LinearMouse](https://github.com/linearmouse/linearmouse) ·
[MonitorControl](https://github.com/MonitorControl/MonitorControl) ·
[Stats](https://github.com/exelban/stats) ·
[Mos](https://github.com/Caldis/Mos) ·
[RClick](https://github.com/wflixu/RClick) ·
[Maccy](https://github.com/p0deje/Maccy) ·
[KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) ·
[switchaudio-osx](https://github.com/deweller/switchaudio-osx) ·
[CodexBar](https://github.com/steipete/CodexBar) ·
[usage](https://github.com/aqua5230/usage) ·
[QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) ·
[Recordly](https://github.com/webadderallorg/Recordly) ·
[Snapzy](https://github.com/duongductrong/Snapzy)
