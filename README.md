# RapidTab

A minimal, very fast Option+Tab window switcher for macOS.

## Why

I love macOS, but I miss Alt+Tab from Windows. I tried all the available Alt+Tab clones, and while they had lots of fancy features, I found them slow and unreliable. So I used Claude Opus 5.5 to make my own, and it feels roughly 100x faster.

Lightweight by design. No features — just fast switching.

## How it's fast

Most window switchers do their slow work (enumerating windows, screenshotting every one of them, drawing an animated UI) *before* they switch, so pressing the shortcut can take a second or more. RapidTab inverts that:

1. **Switch first.** On release of Option, the target window is focused immediately using the same SkyLight calls macOS uses when you click a window — no cooperative activation delay.
2. **Capture later.** Thumbnails are taken in the background *after* you leave a window, plus a gentle low-priority sweep at launch and every ~2 minutes. Opening the switcher only draws cached images.
3. **No UI for quick taps.** A quick Option+Tab (under ~120 ms) flips to the previous window without drawing anything.

## Controls

| Keys | Action |
| --- | --- |
| Option+Tab | Open switcher / next window |
| Shift (while holding Option) | Previous window |
| Arrow keys | Move selection |
| Release Option, Return or Space | Switch to selected window |
| Esc | Cancel |
| Click a tile | Switch to it |
| Click the red × (hover a tile) | Close that window, keep switching |

Windows are shown 16 per page in an even grid; moving past the last tile flips to the next page.

## Build

Requires macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
./scripts/make-signing-cert.sh   # once: self-signed identity so permissions survive rebuilds
./build.sh                       # builds and installs to ~/Applications/RapidTab.app
open ~/Applications/RapidTab.app
```

On first run, grant **Accessibility** (for the keyboard shortcut and focusing windows) and **Screen Recording** (for thumbnails and window titles), then restart the app once. RapidTab enables Launch at Login on first run; toggle it from the ⌥⇥ menu bar icon.

## Limitations

- Only lists windows on the current Space; minimized windows and hidden apps are not shown yet.
- Uses private macOS APIs (`_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `_AXUIElementGetWindow`), resolved at runtime. Not App Store-compatible, and may need updating with future macOS releases.

## Credits

The window-focusing technique follows the approach used by [AltTab](https://github.com/lwouis/alt-tab-macos) and [yabai](https://github.com/koekeishiya/yabai).

## License

MIT — see [LICENSE](LICENSE).
