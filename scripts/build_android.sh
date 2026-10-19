#!/usr/bin/env bash
# Builds the Android app. Tries the full build first and falls back to simpler builds if a step fails,
# so you still get an installable app and a clear note about what was left out.
#
#   VT_TASK     assembleDebug (default) or bundleRelease
#   VT_BG       1 = include the background-service helpers (default), 0 = plain Capacitor
#   VT_BUNDLE   0 = the app loads the website (default), 1 = web files are bundled inside the app (Play Store)
#   VT_HEADLESS 1 = background service runs the page in a hidden WebView when the app screen is closed (default), 0 = leave it out.
#   VT_PUSH     1 = add the Capacitor push-notification plugin (default), 0 = leave it out.
#               Push only works if scripts/google-services.json (from the Firebase console) is in the repo.
#   VERSION_CODE, GITHUB_SHA, GITHUB_RUN_NUMBER are read from the environment (set by GitHub Actions)
#
# When something fails, the reason of every attempt is printed at the very end of this step's log
# (and shown as a warning/error line at the top of the run page), so you do not have to open the folded groups.
set -u
TASK=${VT_TASK:-assembleDebug}
BG=${VT_BG:-1}
BUNDLE=${VT_BUNDLE:-0}
PUSH=${VT_PUSH:-1}
HL=${VT_HEADLESS:-1}
SHA=${GITHUB_SHA:-dev}
RUN=${GITHUB_RUN_NUMBER:-0}
PLUG_CAPGO="@capgo/capacitor-native-biometric@^8"
PLUG_APARAJITA="@aparajita/capacitor-biometric-auth@^10"
PLUG_PUSH="@capacitor/push-notifications@^8"
ALL_PLUG_NAMES="@capgo/capacitor-native-biometric @aparajita/capacitor-biometric-auth @capacitor/push-notifications"
HAS_FCM=0; [ -f scripts/google-services.json ] && HAS_FCM=1
LOGDIR=build-logs
mkdir -p "$LOGDIR"

# npm install, tried twice (a short network hiccup must not fail the whole build)
npmi() { npm install --no-audit --no-fund "$@" || { echo "npm install failed - trying once more"; sleep 4; npm install --no-audit --no-fund "$@"; }; }

# ---------------------------------------------------------------------------------------------
# Checks that must pass for every attempt. Fixes the one mistake that already happened once:
# functions/package.json uploaded to the repo root replaces VText's own package.json, then Capacitor is not installed.
# ---------------------------------------------------------------------------------------------
preflight() {
  local missing="" f
  for f in index.html offline.html manifest.json sw.js logo.svg capacitor.config.json scripts/patch_android.py scripts/make_icons.py; do
    [ -f "$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    echo "::error::These files are missing in the repo:$missing . Upload them with exactly the same folder names (see UPLOAD-PATHS.txt)."
    return 1
  fi
  if ! node -e "const p=JSON.parse(require('fs').readFileSync('package.json','utf8'));const d=Object.assign({},p.devDependencies,p.dependencies);process.exit(d['@capacitor/core']&&d['@capacitor/android']&&d['@capacitor/cli']?0:1)" 2>/dev/null; then
    echo "::warning::package.json in the repo root is not the VText one (it is probably functions/package.json that was uploaded to the root by mistake). The built-in copy is used for this build. Please upload the right package.json to the repo root."
    cat > package.json <<'JSON'
{
  "name": "vtext",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "@capacitor/android": "^8.0.0",
    "@capacitor/app": "^8.0.0",
    "@capacitor/core": "^8.0.0",
    "@capacitor/local-notifications": "^8.0.0",
    "@capacitor/share": "^8.0.0"
  },
  "devDependencies": {
    "@capacitor/assets": "^3.0.5",
    "@capacitor/cli": "^8.0.0"
  }
}
JSON
    rm -rf node_modules package-lock.json
    npmi || { echo "::error::npm install of the Capacitor packages failed"; return 1; }
  fi
  if [ ! -x node_modules/.bin/cap ]; then
    echo "Capacitor is not installed yet - running npm install"
    npmi || { echo "::error::npm install of the Capacitor packages failed"; return 1; }
  fi
  if [ ! -x node_modules/.bin/cap ]; then
    echo "::error::The Capacitor command line tool (@capacitor/cli) is still missing after npm install. Check package.json in the repo root."
    return 1
  fi
  return 0
}

attempt() {  # $1 = fingerprint plugin (capgo|aparajita|none)   $2 = background helpers (1|0)   $3 = push plugin (1|0)
  local plug=$1 bg=$2 push=$3
  echo "--- clean start"
  rm -rf android www
  npm uninstall --no-audit --no-fund $ALL_PLUG_NAMES >/dev/null 2>&1 || true
  echo "--- plugins"
  case "$plug" in
    capgo)     npmi --save "$PLUG_CAPGO"     || return 1 ;;
    aparajita) npmi --save "$PLUG_APARAJITA" || return 1 ;;
  esac
  if [ "$push" = "1" ]; then npmi --save "$PLUG_PUSH" || return 1; fi
  echo "--- web files"
  mkdir -p www
  cp index.html offline.html manifest.json sw.js logo.svg www/ || return 1
  if [ -f config.js ]; then cp config.js www/; fi
  sed -i "s/const APP_BUILD={v:'dev',n:'0'}/const APP_BUILD={v:'$SHA',n:'$RUN'}/" www/index.html
  if [ "$BUNDLE" = "1" ]; then
    node -e "const fs=require('fs'),c=JSON.parse(fs.readFileSync('capacitor.config.json'));delete c.server;fs.writeFileSync('capacitor.config.json',JSON.stringify(c,null,2))" || return 1
  fi
  echo "--- cap add android"
  npx cap add android || return 1
  if [ "$bg" = "1" ]; then export VT_NATIVE=full; else export VT_NATIVE=none; fi
  export VT_PUSH_PLUGIN="$push"
  export VT_HEADLESS="$HL"
  echo "--- patch android project"
  python3 scripts/patch_android.py || return 1
  python3 scripts/make_icons.py || return 1
  echo "--- cap sync"
  npx cap sync android || return 1
  echo "--- gradle $TASK"
  ( cd android && chmod +x gradlew && ./gradlew "$TASK" --stacktrace ) || return 1
  return 0
}

# short single-line reason taken from an attempt's log
reason() {  # $1 = log file
  local f=$1 r=""
  r=$(grep -m1 -A3 'What went wrong' "$f" 2>/dev/null | tail -n +2)
  [ -z "$r" ] && r=$(grep -E '^npm (error|ERR!) ' "$f" 2>/dev/null | grep -vE 'A complete log|debug|^npm (error|ERR!) *$' | head -4)
  [ -z "$r" ] && r=$(grep -E '^(Traceback|[A-Za-z]*Error|[A-Za-z.]*Exception)|ERROR|\[error\]|No such file|cannot stat|command not found|Unable to find' "$f" 2>/dev/null | head -3)
  [ -z "$r" ] && r=$(grep -v '^$' "$f" 2>/dev/null | tail -3)
  printf '%s' "$r" | tr '\n\r' '  ' | cut -c1-700
}

preflight || { echo "::error::The build cannot start (see the message above)."; exit 1; }

# levels are  fingerprint-plugin:background-helpers:push-plugin ; the push plugin is only dropped after the others failed
if [ "$BG" = "1" ]; then
  LEVELS="capgo:1:1 aparajita:1:1 none:1:1 none:1:0 none:0:0"
else
  LEVELS="capgo:0:1 aparajita:0:1 none:0:1 none:0:0"
fi
if [ "$PUSH" != "1" ]; then LEVELS=$(echo "$LEVELS" | sed 's/:1 /:0 /g; s/:1$/:0/' | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ; fi

n=0; TRIED=" "; DROP_PUSH=0; SUMMARY=""
Q=($LEVELS)
while [ ${#Q[@]} -gt 0 ]; do
  lv=${Q[0]}; Q=(${Q[@]+"${Q[@]:1}"})
  plug=${lv%%:*}; rest=${lv#*:}; bg=${rest%%:*}; push=${rest##*:}
  if [ "$DROP_PUSH" = "1" ]; then push=0; fi
  case "$TRIED" in *" $plug:$bg:$push:$HL "*) continue ;; esac
  TRIED="$TRIED$plug:$bg:$push:$HL "
  n=$((n+1))
  echo "::group::Build attempt $n (fingerprint plugin: $plug, background helpers: $bg, push plugin: $push, hidden background page: $HL)"
  attempt "$plug" "$bg" "$push" 2>&1 | tee "$LOGDIR/attempt-$n.log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" = "0" ]; then
    echo "::endgroup::"
    {
      echo "Version 1.0.${VERSION_CODE:-?}"
      echo
      if [ "$plug" = "none" ]; then echo "- Fingerprint plugin: NOT included (the app uses the account-password lock instead)"; else echo "- Fingerprint plugin: included ($plug)"; fi
      if [ "$BG" = "1" ]; then
        if [ "$bg" = "1" ]; then echo "- Background service for message notifications: included"; else echo "- Background service for message notifications: NOT included (build fell back to a plain app)"; fi
        if [ "$bg" = "1" ]; then
          if find android/app/src/main/java -name VTextHeadless.java 2>/dev/null | grep -q .; then echo "- Hidden background page (notifications keep coming after the app is swiped away or the phone restarts): included"
          else echo "- Hidden background page (notifications after the app is swiped away / after a restart): NOT included in this build"; fi
        fi
      fi
      if [ "$push" = "1" ]; then
        if [ "$HAS_FCM" = "1" ]; then echo "- Push notifications (Firebase): included"; else echo "- Push notifications (Firebase): plugin included but OFF - add scripts/google-services.json to the repo and build again"; fi
      elif [ "$PUSH" = "1" ]; then echo "- Push notifications (Firebase): NOT included (the build fell back without the push plugin)"; fi
      if { [ "$plug" = "none" ] || { [ "$BG" = "1" ] && [ "$bg" = "0" ]; } || { [ "$PUSH" = "1" ] && [ "$push" = "0" ]; }; }; then
        echo
        echo "Some optional parts failed to build (attempt $n). The app still works; see the build log for the reason."
        if [ -n "$SUMMARY" ]; then echo; echo "Why the earlier attempts failed:$SUMMARY"; fi
      fi
    } > release-notes.md
    echo "$n" > build-attempt.txt
    cat release-notes.md
    exit 0
  fi
  echo "::endgroup::"
  why=$(reason "$LOGDIR/attempt-$n.log")
  echo "::warning::Build attempt $n failed (fingerprint plugin: $plug, background helpers: $bg, push plugin: $push). Reason: $why"
  SUMMARY="$SUMMARY
- Attempt $n ($plug / background $bg / push $push): $why"
  if [ "$HL" = "1" ] && grep -qE '(VTextHeadless|VTextBoot|VTextService|MainActivity)\.java:[0-9]+: error' "$LOGDIR/attempt-$n.log" 2>/dev/null; then
    HL=0
    Q=("$plug:$bg:$push" ${Q[@]+"${Q[@]}"})   # same build again, without the hidden background page
    SUMMARY="$SUMMARY
- (the hidden background page did not compile; the next attempt leaves it out)"
    echo "The Java code of the hidden background page failed to compile - the next attempt is the same build without it."
  fi
  if [ "$push" = "1" ] && printf '%s' "$why" | grep -qiE 'push-notifications|firebase|google-services|gms'; then
    DROP_PUSH=1
    Q=("$plug:$bg:0" ${Q[@]+"${Q[@]}"})   # same build again, but without the push plugin
    echo "The failure mentions push / Firebase - the next attempt is the same build without the push plugin."
  fi
done
echo
echo "==================== WHY EVERY ATTEMPT FAILED ===================="
printf '%s\n' "$SUMMARY"
echo "=================================================================="
echo "::error::All build attempts failed. $(printf '%s' "$SUMMARY" | tr '\n' ' ' | cut -c1-900)"
exit 1
