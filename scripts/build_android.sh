#!/usr/bin/env bash
# Builds the Android app. Tries the full build first and falls back to simpler builds if a step fails,
# so you still get an installable app and a clear note about what was left out.
#
#   VT_TASK     assembleDebug (default) or bundleRelease
#   VT_BG       1 = include the background-service helpers (default), 0 = plain Capacitor
#   VT_BUNDLE   0 = the app loads the website (default), 1 = web files are bundled inside the app (Play Store)
#   VERSION_CODE, GITHUB_SHA, GITHUB_RUN_NUMBER are read from the environment (set by GitHub Actions)
set -u
TASK=${VT_TASK:-assembleDebug}
BG=${VT_BG:-1}
BUNDLE=${VT_BUNDLE:-0}
SHA=${GITHUB_SHA:-dev}
RUN=${GITHUB_RUN_NUMBER:-0}
PLUG_CAPGO="@capgo/capacitor-native-biometric@^8"
PLUG_APARAJITA="@aparajita/capacitor-biometric-auth@^10"
ALL_PLUG_NAMES="@capgo/capacitor-native-biometric @aparajita/capacitor-biometric-auth"

attempt() {  # $1 = fingerprint plugin (capgo|aparajita|none)   $2 = background helpers (1|0)
  local plug=$1 bg=$2
  rm -rf android www
  npm uninstall $ALL_PLUG_NAMES >/dev/null 2>&1 || true
  case "$plug" in
    capgo)     npm install --save "$PLUG_CAPGO"     || return 1 ;;
    aparajita) npm install --save "$PLUG_APARAJITA" || return 1 ;;
  esac
  mkdir -p www
  cp index.html offline.html manifest.json sw.js logo.svg www/ || return 1
  sed -i "s/const APP_BUILD={v:'dev',n:'0'}/const APP_BUILD={v:'$SHA',n:'$RUN'}/" www/index.html
  if [ "$BUNDLE" = "1" ]; then
    node -e "const fs=require('fs'),c=JSON.parse(fs.readFileSync('capacitor.config.json'));delete c.server;fs.writeFileSync('capacitor.config.json',JSON.stringify(c,null,2))" || return 1
  fi
  npx cap add android || return 1
  if [ "$bg" = "1" ]; then export VT_NATIVE=full; else export VT_NATIVE=none; fi
  python3 scripts/patch_android.py || return 1
  python3 scripts/make_icons.py || return 1
  npx cap sync android || return 1
  ( cd android && chmod +x gradlew && ./gradlew "$TASK" --stacktrace ) || return 1
  return 0
}

if [ "$BG" = "1" ]; then
  LEVELS="capgo:1 aparajita:1 none:1 none:0"
else
  LEVELS="capgo:0 aparajita:0 none:0"
fi

n=0
for lv in $LEVELS; do
  n=$((n+1)); plug=${lv%%:*}; bg=${lv##*:}
  echo "::group::Build attempt $n (fingerprint plugin: $plug, background helpers: $bg)"
  if attempt "$plug" "$bg"; then
    echo "::endgroup::"
    {
      echo "Version 1.0.${VERSION_CODE:-?}"
      echo
      if [ "$plug" = "none" ]; then echo "- Fingerprint plugin: NOT included (the app uses the account-password lock instead)"; else echo "- Fingerprint plugin: included ($plug)"; fi
      if [ "$BG" = "1" ]; then
        if [ "$bg" = "1" ]; then echo "- Background service for message notifications: included"; else echo "- Background service for message notifications: NOT included (build fell back to a plain app)"; fi
      fi
      if { [ "$plug" = "none" ] || { [ "$BG" = "1" ] && [ "$bg" = "0" ]; }; }; then
        echo
        echo "Some optional parts failed to build (attempt $n). The app still works; see the build log for the reason."
      fi
    } > release-notes.md
    echo "$n" > build-attempt.txt
    cat release-notes.md
    exit 0
  fi
  echo "::endgroup::"
  echo "::warning::Build attempt $n failed (fingerprint plugin: $plug, background helpers: $bg). Trying a simpler build..."
done
echo "::error::All build attempts failed. Open the failed step's log to see the first error."
exit 1
