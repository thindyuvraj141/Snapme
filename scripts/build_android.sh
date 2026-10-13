#!/usr/bin/env bash
# Builds the Android app. Tries the full build first and falls back to simpler builds if a step fails,
# so you still get an installable app and a clear note about what was left out.
#
#   VT_TASK     assembleDebug (default) or bundleRelease
#   VT_BG       1 = include the background-service helpers (default), 0 = plain Capacitor
#   VT_BUNDLE   0 = the app loads the website (default), 1 = web files are bundled inside the app (Play Store)
#   VT_PUSH     1 = add the Capacitor push-notification plugin (default), 0 = leave it out.
#               Push only works if scripts/google-services.json (from the Firebase console) is in the repo.
#   VERSION_CODE, GITHUB_SHA, GITHUB_RUN_NUMBER are read from the environment (set by GitHub Actions)
set -u
TASK=${VT_TASK:-assembleDebug}
BG=${VT_BG:-1}
BUNDLE=${VT_BUNDLE:-0}
PUSH=${VT_PUSH:-1}
SHA=${GITHUB_SHA:-dev}
RUN=${GITHUB_RUN_NUMBER:-0}
PLUG_CAPGO="@capgo/capacitor-native-biometric@^8"
PLUG_APARAJITA="@aparajita/capacitor-biometric-auth@^10"
PLUG_PUSH="@capacitor/push-notifications@^8"
ALL_PLUG_NAMES="@capgo/capacitor-native-biometric @aparajita/capacitor-biometric-auth @capacitor/push-notifications"
HAS_FCM=0; [ -f scripts/google-services.json ] && HAS_FCM=1

attempt() {  # $1 = fingerprint plugin (capgo|aparajita|none)   $2 = background helpers (1|0)   $3 = push plugin (1|0)
  local plug=$1 bg=$2 push=$3
  rm -rf android www
  npm uninstall $ALL_PLUG_NAMES >/dev/null 2>&1 || true
  case "$plug" in
    capgo)     npm install --save "$PLUG_CAPGO"     || return 1 ;;
    aparajita) npm install --save "$PLUG_APARAJITA" || return 1 ;;
  esac
  if [ "$push" = "1" ]; then npm install --save "$PLUG_PUSH" || return 1; fi
  mkdir -p www
  cp index.html offline.html manifest.json sw.js logo.svg www/ || return 1
  if [ -f config.js ]; then cp config.js www/; fi
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

# levels are  fingerprint-plugin:background-helpers:push-plugin ; the push plugin is only dropped after the others failed
if [ "$BG" = "1" ]; then
  LEVELS="capgo:1:1 aparajita:1:1 none:1:1 none:1:0 none:0:0"
else
  LEVELS="capgo:0:1 aparajita:0:1 none:0:1 none:0:0"
fi
if [ "$PUSH" != "1" ]; then LEVELS=$(echo "$LEVELS" | sed 's/:1 /:0 /g; s/:1$/:0/' | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ; fi

n=0
for lv in $LEVELS; do
  n=$((n+1)); plug=${lv%%:*}; rest=${lv#*:}; bg=${rest%%:*}; push=${rest##*:}
  echo "::group::Build attempt $n (fingerprint plugin: $plug, background helpers: $bg, push plugin: $push)"
  if attempt "$plug" "$bg" "$push"; then
    echo "::endgroup::"
    {
      echo "Version 1.0.${VERSION_CODE:-?}"
      echo
      if [ "$plug" = "none" ]; then echo "- Fingerprint plugin: NOT included (the app uses the account-password lock instead)"; else echo "- Fingerprint plugin: included ($plug)"; fi
      if [ "$BG" = "1" ]; then
        if [ "$bg" = "1" ]; then echo "- Background service for message notifications: included"; else echo "- Background service for message notifications: NOT included (build fell back to a plain app)"; fi
      fi
      if [ "$push" = "1" ]; then
        if [ "$HAS_FCM" = "1" ]; then echo "- Push notifications (Firebase): included"; else echo "- Push notifications (Firebase): plugin included but OFF - add scripts/google-services.json to the repo and build again"; fi
      elif [ "$PUSH" = "1" ]; then echo "- Push notifications (Firebase): NOT included (the build fell back without the push plugin)"; fi
      if { [ "$plug" = "none" ] || { [ "$BG" = "1" ] && [ "$bg" = "0" ]; } || { [ "$PUSH" = "1" ] && [ "$push" = "0" ]; }; }; then
        echo
        echo "Some optional parts failed to build (attempt $n). The app still works; see the build log for the reason."
      fi
    } > release-notes.md
    echo "$n" > build-attempt.txt
    cat release-notes.md
    exit 0
  fi
  echo "::endgroup::"
  echo "::warning::Build attempt $n failed (fingerprint plugin: $plug, background helpers: $bg, push plugin: $push). Trying a simpler build..."
done
echo "::error::All build attempts failed. Open the failed step's log to see the first error."
exit 1
