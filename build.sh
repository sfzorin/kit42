#!/bin/zsh
# Builds Suite42 apps into build/<App>.app.
#   ./build.sh                 # all apps
#   ./build.sh PDF42           # one app
#   ./build.sh PDF42 install   # and copy to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

typeset -A LABEL COLORS
LABEL=(PDF42 PDF DOC42 DOC XLS42 XLS IMG42 IMG)
COLORS=(PDF42 "0.95 0.30 0.25 0.70 0.08 0.20" DOC42 "0.25 0.55 0.98 0.10 0.28 0.75" XLS42 "0.20 0.75 0.45 0.05 0.48 0.28" IMG42 "0.66 0.40 0.98 0.40 0.16 0.74")

APPS=(${1:-})
[[ -z "${1:-}" ]] && APPS=($(for a in PDF42 DOC42 XLS42 IMG42; do [[ -d Sources/$a ]] && echo $a; done))
INSTALL=${2:-}

swift build -c release

for APP_NAME in $APPS; do
  RES="Resources/$APP_NAME"
  if [[ ! -f "$RES/AppIcon.icns" ]]; then
    swift scripts/make_icon.swift "$RES" "${LABEL[$APP_NAME]}" ${=COLORS[$APP_NAME]}
    iconutil -c icns "$RES/AppIcon.iconset" -o "$RES/AppIcon.icns"
    rm -rf "$RES/AppIcon.iconset"
  fi

  APP="build/$APP_NAME.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/"
  cp "$RES/Info.plist" "$APP/Contents/"
  cp "$RES/AppIcon.icns" "$APP/Contents/Resources/"
  [[ -d .build/release/Suite42_$APP_NAME.bundle ]] && cp -R ".build/release/Suite42_$APP_NAME.bundle" "$APP/Contents/Resources/"
  codesign --force --deep -s - "$APP"
  echo "Built $APP"

  if [[ "$INSTALL" == "install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/$APP_NAME.app
    cp -R "$APP" ~/Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/$APP_NAME.app
    echo "Installed ~/Applications/$APP_NAME.app"
  fi
done
