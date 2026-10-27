# Weather app installer

iOS 12 for iPad has no Weather app. This installer rebuilds the iPhone Weather app from iOS 12.5.8,
plus its animated weather backgrounds, so the WeatherPad tweak can turn it into an iPad app.

**Apple's files are not part of this repository.** The installer downloads them on your own Mac,
at install time, straight from Apple's update server (the iPhone 5s iOS 12.5.8 update, build 16H88).
It fetches only the pieces it needs, about 57 MB (1.2 MB with `--no-backgrounds`), instead of the
whole 2.26 GB update. Every file is checked against the update's own manifests (SHA-1 for the app,
size and checksum from the update's file list for the backgrounds) before anything is installed.
The only file from this repo that ends up in the app is the launch screen in `launch/`.

## Requirements

- An iPad on iOS 12, jailbroken (tested on an iPad mini 2 with iOS 12.5.8, checkra1n and odysseyra1n)
- AppSync Unified
- The WeatherPad tweak, from the repo `https://itsallexb.github.io/ios-legacy/`
- A Mac with macOS 11 or later, Python 3 (`xcode-select --install`) and `ldid` from Homebrew
  (`brew install ldid`)
- SSH access to the iPad as root, for installing from the Mac

## Usage

Install over Wi-Fi (you'll be asked for the iPad's root password once):

```sh
./install-weather.sh --host 192.168.1.20
```

Over USB with checkra1n's built-in SSH server (dropbear on port 44), forward a port first:

```sh
iproxy 2222 44 &
./install-weather.sh --host 127.0.0.1 --port 2222
```

Only build, without touching the iPad (the result goes to `./WeatherPad-build`):

```sh
./install-weather.sh
```

Remove it from the iPad again:

```sh
./install-weather.sh --uninstall --host 192.168.1.20
```

| Option | Meaning |
| --- | --- |
| `--host IP` | The iPad's address. Without it, the installer only builds. |
| `--port N` | SSH port (default 22). |
| `--user U` | SSH user (default root). |
| `--out DIR` | Build into `DIR` and keep it there. |
| `--no-backgrounds` | Skip the animated backgrounds. |
| `--dry-run` | Print the commands it would run on the iPad. Downloads and changes nothing. |

## What it changes

On the Mac, in the build folder:

- `Weather.app` gets iPad support in its `Info.plist` (device family iPhone and iPad, all four
  orientations, WeatherPad's launch screen), loses `_CodeSignature`, and is fakesigned with `ldid`
  using the entitlements Apple gave each binary (read from the binaries with `ldid -e`).

On the iPad (`device/weather-device.sh`, run as root):

- Installs `/Applications/Weather.app` and runs `uicache`.
- Installs the backgrounds into `/System/Library/PrivateFrameworks/WeatherUI.framework/`. iOS 12 for
  iPad has the WeatherUI code but not this folder.
- Moves the iPad's `ClimateProxy.app` stub to `/var/root/weather-port-backup/`, because it uses the
  same bundle id as the Weather app. `--uninstall` puts it back.

## If the download stops working

The installer uses one specific Apple update file. If Apple moves it, the installer looks it up in
Apple's public update catalog (`mesu.apple.com`) and uses the new address. If Apple stops offering
it entirely, the installer stops with an error and installs nothing. Please open an issue.
