#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 itsAllexB
#
# Runs as root ON THE iPAD. install-weather.sh copies it over and calls it; you can also run it
# yourself after copying the build folder over:
#   bash weather-device.sh install /path/to/build    (folder holding Weather.app [+ WeatherUI.framework])
#   bash weather-device.sh uninstall
# Uses only commands found on checkra1n/odysseyra1n (Procursus) and other iOS 12 jailbreaks.
set -u
R="${WEATHERPAD_TEST_ROOT:-}"   # empty on a real device; lets the logic be tested in a folder
APP="$R/Applications/Weather.app"
WUI="$R/System/Library/PrivateFrameworks/WeatherUI.framework"
CP="$R/System/Library/CoreServices/ClimateProxy.app"
BACKUP="$R/var/root/weather-port-backup"

say()  { echo "[iPad] $*"; }
fail() { echo "[iPad] FAILED: $*"; exit 1; }

case "$(uname -m)" in iPad*) ;; *) fail "this is not an iPad ($(uname -m))" ;; esac
case "$(uname -r)" in 18.*) ;; *) fail "WeatherPad's Weather app is for iOS 12 only" ;; esac
[ "$(id -u)" = 0 ] || fail "run this as root"

bundle_id() {   # CFBundleIdentifier of an app, or empty
    local p
    for p in plutil /binpack/usr/bin/plutil; do
        if command -v "$p" >/dev/null 2>&1; then "$p" -key CFBundleIdentifier "$1/Info.plist" 2>/dev/null; return; fi
    done
    # No plutil: Apple's iOS 12 iPad ClimateProxy stub is always com.apple.weather.
    [ -d "$1" ] && echo com.apple.weather
}

install() {
    local src="$1"
    [ -d "$src/Weather.app" ] || fail "no Weather.app in $src"
    command -v dpkg >/dev/null 2>&1 && ! dpkg -s com.itsallexb.weatherpad >/dev/null 2>&1 &&
        say "Note: the WeatherPad tweak is not installed yet. Get it from https://itsallexb.github.io/ios-legacy/"
    mkdir -p "$BACKUP"
    if [ -d "$CP" ] && [ "$(bundle_id "$CP")" = com.apple.weather ]; then
        # The iPad's ClimateProxy stub (it only hosts the Today widget) uses the same bundle id
        # as the real app, so it is moved aside. Uninstalling puts it back.
        [ -e "$BACKUP/ClimateProxy.app" ] && fail "$BACKUP/ClimateProxy.app already exists; please check it"
        say "Moving ClimateProxy.app to $BACKUP (it would clash with Weather.app)"
        mv "$CP" "$BACKUP/" || fail "could not move ClimateProxy.app"
    elif [ -d "$CP" ]; then
        say "ClimateProxy.app does not clash; skipping the duplicate Today widget"
        rm -rf "$src/Weather.app/PlugIns"
    fi

    say "Installing $APP"
    rm -rf "$APP"
    mkdir -p "$(dirname "$APP")"
    cp -R "$src/Weather.app" "$APP" || fail "could not copy Weather.app"
    chown -R root:wheel "$APP"
    chmod -R u=rwX,go=rX "$APP"
    chmod 755 "$APP/Weather"
    [ -f "$APP/PlugIns/WeatherAppTodayWidget.appex/WeatherAppTodayWidget" ] &&
        chmod 755 "$APP/PlugIns/WeatherAppTodayWidget.appex/WeatherAppTodayWidget"

    if [ -d "$src/WeatherUI.framework" ]; then
        say "Installing the animated backgrounds into $WUI"
        rm -rf "$WUI"
        cp -R "$src/WeatherUI.framework" "$WUI" || fail "could not copy WeatherUI.framework"
        chown -R root:wheel "$WUI"
        find "$WUI" -type d -exec chmod 755 {} +
        find "$WUI" -type f -exec chmod 644 {} +
    fi

    say "Registering Weather.app with SpringBoard"
    uicache -p "$APP" || fail "uicache failed"
    say "Done. Weather is on your home screen."
}

uninstall() {
    if [ -d "$APP" ]; then
        say "Removing $APP"
        uicache -u "$APP" >/dev/null 2>&1
        rm -rf "$APP"
    fi
    if [ -d "$WUI" ]; then
        # iOS 12 for iPad has no WeatherUI.framework folder (its code lives in the dyld cache),
        # so the whole folder came from this installer.
        say "Removing the animated backgrounds ($WUI)"
        rm -rf "$WUI"
    fi
    if [ -d "$BACKUP/ClimateProxy.app" ] && [ ! -e "$CP" ]; then
        say "Restoring ClimateProxy.app"
        mv "$BACKUP/ClimateProxy.app" "$CP" || fail "could not restore ClimateProxy.app"
        uicache -p "$CP" || uicache -a
    fi
    rmdir "$BACKUP" 2>/dev/null
    say "Done. Weather has been removed."
}

case "${1:-}" in
    install)   install "${2:?folder}" ;;
    uninstall) uninstall ;;
    *) echo "usage: $0 install FOLDER | uninstall"; exit 2 ;;
esac
