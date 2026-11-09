# Amplify

A small macOS menu bar app that boosts your Mac's volume beyond 100% and lets you switch output devices — styled like the Control Center Sound module, with native Liquid Glass on macOS 26 and the standard frosted panel on earlier versions.

## Features

- **Volume slider** with a one-tap **booster** toggle beside it
- **Booster remembered per output device** (e.g. on for the MacBook speakers, off for earbuds)
- **Booster strength**: 125%, 150%, 175% or 200% (each step is stronger than its label: 1.5×, 2×, 2.5×, 3×)
- **Clean at high gain**: a look-ahead peak limiter turns peaks down before they clip, so loud boosts don't sound harsh
- **Low latency**: adds only ~15 ms, even on Bluetooth
- **Output switcher** for speakers, headphones and AirPlay (virtual devices like BlackHole are hidden)
- **Start at Login** and booster strength in the gear menu

## Requirements

- macOS 14.2 (Sonoma) or later — the first release with Core Audio process taps
- Apple silicon or Intel (universal app)

Liquid Glass is used on macOS 26 (Tahoe) and later; older versions get the system's frosted popover material.

## Install

1. Download `Amplify.zip` from [Releases](../../releases) and unzip it.
2. Move `Amplify.app` to `/Applications`.
3. The app is not notarized, so the first time either right-click it and choose **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Amplify.app
   ```
4. Click the speaker icon in the menu bar. When you first turn the booster on, allow **audio capture** — Amplify needs it to boost the audio playing on your Mac.

Right-click the menu bar icon for Launch at Login and Quit.

## Build from source

Needs the Xcode Command Line Tools (Swift 6) with the macOS 26 SDK or newer. `build.sh` produces a universal binary that runs on macOS 14.2+.

```bash
./build.sh
open build/Amplify.app
```

## How it works

When the booster is on, Amplify creates a Core Audio process tap on the current output device (excluding itself) and mutes the original audio. The tap feeds a lock-free buffer, and a separate IO callback on the output device applies the gain and limiter and plays the result. Keeping the tap in its own aggregate device, separate from the output, avoids Core Audio delaying it by the device's full latency. When the booster is off, nothing is tapped or processed.

## License

MIT
