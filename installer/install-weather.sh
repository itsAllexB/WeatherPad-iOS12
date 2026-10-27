#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 itsAllexB
#
# Rebuilds Apple's iPhone Weather app (iOS 12.5.8) and its animated backgrounds for the iPad,
# for use with the WeatherPad tweak. Apple's files are downloaded from Apple's own update
# server on your Mac at install time; none of them are part of this repository.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/fetch_weather.py"
DEVICE_SCRIPT="$HERE/device/weather-device.sh"
REMOTE_DIR=/var/tmp/weatherpad-install

usage() {
    cat <<EOF
Usage:
  $0 [--out DIR]                     Build Weather.app and the backgrounds into DIR
                                     (default: ./WeatherPad-build). Nothing is installed.
  $0 --host IP [--port N] [--user U] Build, then install on the iPad over SSH.
  $0 --uninstall --host IP [...]     Remove Weather from the iPad again.

Options:
  --host IP         iPad address (for checkra1n over USB: run 'iproxy 2222 44' and use
                    --host 127.0.0.1 --port 2222)
  --port N          SSH port (default 22)
  --user U          SSH user (default root)
  --out DIR         Keep the build in DIR (when installing, a temporary folder is used otherwise)
  --no-backgrounds  Skip the animated backgrounds (about 55 MB less to download)
  --dry-run         Show what would run on the iPad; download and change nothing
  -h, --help        Show this help
EOF
}

HOST="" PORT=22 USER_NAME=root OUT="" BACKGROUNDS=1 UNINSTALL=0 DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:?--host needs a value}"; shift 2 ;;
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --user) USER_NAME="${2:?--user needs a value}"; shift 2 ;;
        --out) OUT="${2:?--out needs a value}"; shift 2 ;;
        --no-backgrounds) BACKGROUNDS=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is missing. $2"; }

[ "$(uname -s)" = Darwin ] || die "this installer runs on a Mac."
[ "$UNINSTALL" = 0 ] || [ -n "$HOST" ] || die "--uninstall needs --host."

# ---- SSH: one connection, so the password is asked only once ------------------------------
CTL_DIR="" WORK="" OUT_CREATED=0 OK=0
cleanup() {
    if [ -n "$CTL_DIR" ]; then
        ssh -o ControlPath="$CTL_DIR/c" -O exit "$HOST" >/dev/null 2>&1 || true
        rm -rf "$CTL_DIR"
    fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    if [ "$OK" = 0 ] && [ "$OUT_CREATED" = 1 ]; then rm -rf "$OUT"; fi
}
trap cleanup EXIT

SSH_OPTS=() SCP_O=()
setup_ssh() {
    need ssh "It ships with macOS."
    need scp "It ships with macOS."
    CTL_DIR="$(mktemp -d /tmp/weatherpad-ssh.XXXXXX)"
    SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL_DIR/c" -o ControlPersist=300)
    # Old dropbear servers only speak the legacy scp protocol; newer scp needs -O for that.
    if ! scp -O 2>&1 | grep -qiE 'illegal|unknown'; then SCP_O=(-O); fi
}
remote() {   # run a command on the iPad
    if [ "$DRY" = 1 ]; then echo "  [dry-run] ssh -p $PORT $USER_NAME@$HOST $*"; return; fi
    ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@$HOST" "$@"
}
remote_script() {   # run the device script on the iPad (sent over stdin)
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] ssh -p $PORT $USER_NAME@$HOST bash -s -- $* < device/weather-device.sh"
        return
    fi
    ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@$HOST" bash -s -- "$@" < "$DEVICE_SCRIPT"
}
copy_to_ipad() {
    if [ "$DRY" = 1 ]; then echo "  [dry-run] scp ${SCP_O[*]:-} -r -P $PORT $* $USER_NAME@$HOST:$REMOTE_DIR/"; return; fi
    scp "${SCP_O[@]+"${SCP_O[@]}"}" "${SSH_OPTS[@]}" -q -r -P "$PORT" "$@" "$USER_NAME@$HOST:$REMOTE_DIR/"
}

# ---- Uninstall ----------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    setup_ssh
    step "Removing Weather from $HOST (you may be asked for the iPad's root password)"
    remote_script uninstall
    OK=1
    exit 0
fi

# ---- Build --------------------------------------------------------------------------------
step "Checking the tools on this Mac"
need python3 "Install it with: xcode-select --install   (or: brew install python)"
python3 -I -c 'import lzma, ssl, plistlib' 2>/dev/null || die "python3 lacks lzma/ssl. Try: brew install python"
need aa "aa ships with macOS 11 Big Sur or later."
need lsbom "lsbom ships with macOS."
need cksum "cksum ships with macOS."
need ldid "Install it with: brew install ldid"
echo "  All set."

if [ -n "$HOST" ]; then setup_ssh; fi
if [ "$DRY" = 1 ]; then
    step "[dry-run] Would download from Apple and build Weather.app$([ $BACKGROUNDS = 1 ] && echo ' and WeatherUI.framework')"
    BUILD="${OUT:-<temporary folder>}"
else
    if [ -n "$OUT" ] || [ -z "$HOST" ]; then
        OUT="${OUT:-$PWD/WeatherPad-build}"
        [ -e "$OUT" ] && die "$OUT already exists. Delete it or choose another folder with --out."
        mkdir -p "$(dirname "$OUT")"
        OUT_CREATED=1
        BUILD="$OUT"
    else
        WORK="$(mktemp -d /tmp/weatherpad-build.XXXXXX)"
        BUILD="$WORK/build"
    fi

    step "Downloading the iPhone 5s iOS 12.5.8 Weather app from Apple"
    args=(fetch "$BUILD")
    [ "$BACKGROUNDS" = 1 ] || args+=(--no-backgrounds)
    python3 -I "$HELPER" "${args[@]}"

    step "Preparing Weather.app for the iPad"
    APP="$BUILD/Weather.app"
    WIDGET="$APP/PlugIns/WeatherAppTodayWidget.appex/WeatherAppTodayWidget"
    ENTS="$(mktemp -d /tmp/weatherpad-ents.XXXXXX)"
    # Fakesign both binaries with the entitlements Apple gave them (read from the binaries).
    ldid -e "$APP/Weather" > "$ENTS/app.plist"
    ldid -e "$WIDGET" > "$ENTS/widget.plist"
    ldid -S"$ENTS/app.plist" "$APP/Weather"
    ldid -S"$ENTS/widget.plist" "$WIDGET"
    rm -rf "$ENTS" "$APP/_CodeSignature" "$APP/PlugIns/WeatherAppTodayWidget.appex/_CodeSignature"
    echo "  Fakesigned Weather and its Today widget with their original entitlements."
    python3 -I "$HELPER" patch-plist "$APP/Info.plist"
    cp -R "$HERE/launch/WeatherLaunch.storyboardc" "$APP/"
    echo "  Info.plist: iPhone + iPad, all four iPad orientations, WeatherPad launch screen."
fi

if [ -z "$HOST" ]; then
    OK=1
    step "Done. The build is in: $BUILD"
    echo "  To install it on your iPad, run:  $0 --host <iPad IP> [--port N]"
    echo "  or copy the folder to the iPad and run device/weather-device.sh install <folder> as root."
    exit 0
fi

# ---- Install on the iPad ------------------------------------------------------------------
step "Installing on $HOST (you may be asked for the iPad's root password)"
remote "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
items=("$BUILD/Weather.app")
[ "$BACKGROUNDS" = 1 ] && items+=("$BUILD/WeatherUI.framework")
echo "  Copying files to the iPad ..."
copy_to_ipad "${items[@]}"
remote_script install "$REMOTE_DIR"
remote "rm -rf $REMOTE_DIR"
OK=1
step "All done. Make sure the WeatherPad tweak is installed (https://itsallexb.github.io/ios-legacy/)."
