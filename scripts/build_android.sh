#!/usr/bin/env bash
# Builds the Android app. Tries the full build first and falls back to simpler builds if a step fails,
# so you still get an installable app and a clear note about what was left out.
#
#   VT_TASK     assembleDebug (default) or bundleRelease
#   VT_BG       1 = include Snapme's native helpers (default), 0 = plain Capacitor
#   VT_BUNDLE   0 = the app loads the website (default), 1 = web files are bundled inside the app (Play Store)
#   (Snapme has no background service any more: no hidden page, no "running" notification, no start at boot. VT_HEADLESS is ignored.)
#   VT_PUSH     1 = add the Capacitor push-notification plugin (default), 0 = leave it out.
#               Push only works if scripts/google-services.json (from the Firebase console) is in the repo.
#   VT_ONESIGNAL 1 = also add OneSignal (the free Cloudflare Worker route, see push-worker/) (default), 0 = leave it out.
#               If it does not compile the build is repeated without it (the app then still has the Firebase / Expo route).
#               The OneSignal App ID (public, NOT the secret REST key) is read from VT_ONESIGNAL_APP_ID, scripts/onesignal-app-id.txt or the built-in default.
#   VT_SHAREIN  1 = also add "Share to Snapme" (Snapme is listed in the Android Share sheet for photos) (default), 0 = leave it out.
#               If it does not compile the build is repeated without it. Only part of builds with the native helpers (VT_BG=1).
#   VERSION_CODE, GITHUB_SHA, GITHUB_RUN_NUMBER are read from the environment (set by GitHub Actions)
#
# When something fails, the reason of every attempt is printed at the very end of this step's log
# (and shown as a warning/error line at the top of the run page), so you do not have to open the folded groups.
set -u
TASK=${VT_TASK:-assembleDebug}
BG=${VT_BG:-1}
BUNDLE=${VT_BUNDLE:-0}
PUSH=${VT_PUSH:-1}
OS=${VT_ONESIGNAL:-1}
SH=${VT_SHAREIN:-1}
SHARE_ON=$SH   # switched to 0 when the build with "Share to Snapme" failed because of it
SHA=${GITHUB_SHA:-dev}
RUN=${GITHUB_RUN_NUMBER:-0}
PLUG_CAPGO="@capgo/capacitor-native-biometric@^8"
PLUG_APARAJITA="@aparajita/capacitor-biometric-auth@^10"
PLUG_PUSH="@capacitor/push-notifications@^8"
ALL_PLUG_NAMES="@capgo/capacitor-native-biometric @aparajita/capacitor-biometric-auth @capacitor/push-notifications"
HAS_FCM=0; [ -f scripts/google-services.json ] && HAS_FCM=1
# OneSignal App ID: a public id (NOT the secret REST key). Variable first, then the file, then the built-in default.
OSID=${VT_ONESIGNAL_APP_ID:-}
if [ -z "$OSID" ] && [ -f scripts/onesignal-app-id.txt ]; then OSID=$(tr -d ' \r\n' < scripts/onesignal-app-id.txt); fi
if [ -z "$OSID" ]; then OSID="eaee4d46-0219-44e9-ac45-10b45587223e"; fi
export VT_ONESIGNAL_APP_ID="$OSID"
LOGDIR=build-logs
mkdir -p "$LOGDIR"

# npm install, tried twice (a short network hiccup must not fail the whole build)
npmi() { npm install --no-audit --no-fund "$@" || { echo "npm install failed - trying once more"; sleep 4; npm install --no-audit --no-fund "$@"; }; }

# ---------------------------------------------------------------------------------------------
# Checks that must pass for every attempt. Fixes the one mistake that already happened once:
# functions/package.json uploaded to the repo root replaces Snapme's own package.json, then Capacitor is not installed.
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
    echo "::warning::package.json in the repo root is not the Snapme one (it is probably functions/package.json that was uploaded to the root by mistake). The built-in copy is used for this build. Please upload the right package.json to the repo root."
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

attempt() {  # $1 = fingerprint plugin (capgo|aparajita|none)   $2 = native helpers (1|0)   $3 = push plugin (1|2|0)   $4 = OneSignal (1|0)
  local plug=$1 bg=$2 push=$3 os=${4:-0}
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
  if [ "$bg" = "1" ] && [ "$os" = "1" ]; then export VT_ONESIGNAL=1; else export VT_ONESIGNAL=0; fi
  if [ "$bg" = "1" ] && [ "$SHARE_ON" = "1" ]; then export VT_SHAREIN=1; else export VT_SHAREIN=0; fi
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

# levels are  fingerprint-plugin:native-helpers:push-plugin:onesignal ; OneSignal and the push plugin are only dropped after the others failed
if [ "$BG" = "1" ]; then
  LEVELS="capgo:1:1:1 aparajita:1:1:1 none:1:1:1 none:1:1:0 none:1:2:0 none:1:0:0 none:0:0:0"
else
  LEVELS="capgo:0:1:0 aparajita:0:1:0 none:0:1:0 none:0:0:0"
fi
if [ "$PUSH" != "1" ]; then LEVELS=$(echo "$LEVELS" | sed -E 's/:[12]:([01])( |$)/:0:\1\2/g' | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ; fi
if [ "$OS" != "1" ]; then LEVELS=$(echo "$LEVELS" | sed -E 's/:[01]( |$)/:0\1/g' | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ; fi

n=0; TRIED=" "; DROP_PUSH=0; DROP_OS=0; SUMMARY=""
Q=($LEVELS)
while [ ${#Q[@]} -gt 0 ]; do
  lv=${Q[0]}; Q=(${Q[@]+"${Q[@]:1}"})
  plug=${lv%%:*}; rest=${lv#*:}; bg=${rest%%:*}; rest=${rest#*:}; push=${rest%%:*}; os=${rest##*:}
  if [ "$DROP_PUSH" = "1" ]; then push=0; fi
  if [ "$DROP_OS" = "1" ]; then os=0; fi
  case "$TRIED" in *" $plug:$bg:$push:$os:$SHARE_ON "*) continue ;; esac
  TRIED="$TRIED$plug:$bg:$push:$os:$SHARE_ON "
  n=$((n+1))
  echo "::group::Build attempt $n (fingerprint plugin: $plug, native helpers: $bg, push plugin: $push, OneSignal: $os)"
  attempt "$plug" "$bg" "$push" "$os" 2>&1 | tee "$LOGDIR/attempt-$n.log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" = "0" ]; then
    echo "::endgroup::"
    {
      echo "Version 1.0.${VERSION_CODE:-?}"
      echo
      if [ "$plug" = "none" ]; then echo "- Fingerprint plugin: NOT included (the app uses the account-password lock instead)"; else echo "- Fingerprint plugin: included ($plug)"; fi
      if [ "$BG" = "1" ]; then
        if [ "$bg" = "1" ]; then echo "- Native helpers (permissions, fingerprint lock, save to gallery, open a chat from a notification): included"; else echo "- Native helpers: NOT included (build fell back to a plain app)"; fi
        echo "- No background service: Snapme does not run in the background and shows no \"running\" notification. Notifications while the app is closed come from the push service."
      fi
      if [ "$push" = "1" ] || [ "$push" = "2" ]; then
        if [ "$push" = "1" ]; then echo "- Snapme's own messaging service: included (Expo message pushes can wake the app)"; fi
        if [ "$push" = "2" ]; then echo "- Snapme's own messaging service: NOT included (it did not build). Pushes that carry a notification (admin panel) still show when the app is closed; Expo message pushes need that service."; fi
        if [ "$HAS_FCM" = "1" ]; then echo "- Push notifications (Firebase): included"; else echo "- Push notifications (Firebase): plugin included but OFF - add scripts/google-services.json to the repo and build again"; fi
      elif [ "$PUSH" = "1" ]; then echo "- Push notifications (Firebase): NOT included (the build fell back without the push plugin)"; fi
      if [ "$SH" = "1" ] && [ "$BG" = "1" ]; then
        if [ "$SHARE_ON" = "1" ] && [ "$bg" = "1" ]; then echo "- Share to Snapme (photos from the Gallery and other apps, Android Share sheet): included"
        else echo "- Share to Snapme: NOT included (it did not build). The rest of the app is complete; see the build log for the reason."; fi
      fi
      if [ "$os" = "1" ] && [ "$bg" = "1" ]; then echo "- OneSignal (free Cloudflare Worker route): included (App ID ${OSID:0:8}...)"
      elif [ "$OS" = "1" ] && [ "$BG" = "1" ]; then echo "- OneSignal (free Cloudflare Worker route): NOT included (it did not build). Messages and snaps still go through Expo; likes, comments and friend requests need OneSignal."; fi
      if { [ "$plug" = "none" ] || { [ "$BG" = "1" ] && [ "$bg" = "0" ]; } || { [ "$PUSH" = "1" ] && [ "$push" != "1" ]; } || { [ "$OS" = "1" ] && [ "$BG" = "1" ] && [ "$os" != "1" ]; } || { [ "$SH" = "1" ] && [ "$BG" = "1" ] && [ "$SHARE_ON" != "1" ]; }; }; then
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
  echo "::warning::Build attempt $n failed (fingerprint plugin: $plug, native helpers: $bg, push plugin: $push, OneSignal: $os). Reason: $why"
  SUMMARY="$SUMMARY
- Attempt $n ($plug / helpers $bg / push $push / OneSignal $os): $why"
  # (the patch step prints "OneSignal ..." lines in every attempt, so only real error lines count here)
  # "Share to Snapme" (VTextSharePlugin) did not compile: the same build again without it (every later attempt is without it too)
  if [ "$SHARE_ON" = "1" ] && [ "$bg" = "1" ] && grep -E 'VTextSharePlugin\.java' "$LOGDIR/attempt-$n.log" 2>/dev/null | grep -qiE 'error'; then
    SHARE_ON=0
    Q=("$plug:$bg:$push:$os" ${Q[@]+"${Q[@]}"})
    SUMMARY="$SUMMARY
- (Share to Snapme did not build; the next attempt is the same build without it)"
    echo "The log mentions Share to Snapme - the next attempt is the same build without it."
  elif [ "$os" = "1" ] && { printf '%s' "$why" | grep -qiE 'onesignal|VTextPush|VTextApp' || grep -E 'VTextPushPlugin\.java|VTextApp\.java|com\.onesignal|onesignal\.' "$LOGDIR/attempt-$n.log" 2>/dev/null | grep -qiE 'error|cannot find|does not exist|incompatible|could not|failed|duplicate|conflict|unresolved'; }; then
    DROP_OS=1
    Q=("$plug:$bg:$push:0" ${Q[@]+"${Q[@]}"})   # OneSignal did not build: the same build again, without it (every later attempt is without it too)
    SUMMARY="$SUMMARY
- (OneSignal did not build; the next attempt is the same build without OneSignal)"
    echo "The log mentions OneSignal - the next attempt is the same build without OneSignal."
  elif [ "$push" = "1" ] && grep -qE 'VTextFcmService|MessagingService' "$LOGDIR/attempt-$n.log" 2>/dev/null; then
    Q=("$plug:$bg:2:$os" ${Q[@]+"${Q[@]}"})   # Snapme's own messaging service did not build: the same build with the push plugin but without that service
    SUMMARY="$SUMMARY
- (Snapme's own messaging service did not build; the next attempt keeps the push plugin and leaves that service out)"
    echo "The log mentions the messaging service - the next attempt keeps the push plugin but leaves Snapme's own messaging service out."
  elif [ "$push" = "1" ] && printf '%s' "$why" | grep -qiE 'push-notifications|firebase|google-services|gms'; then
    DROP_PUSH=1
    Q=("$plug:$bg:0:$os" ${Q[@]+"${Q[@]}"})   # same build again, but without the push plugin
    echo "The failure mentions push / Firebase - the next attempt is the same build without the push plugin."
  fi
done
echo
echo "==================== WHY EVERY ATTEMPT FAILED ===================="
printf '%s\n' "$SUMMARY"
echo "=================================================================="
echo "::error::All build attempts failed. $(printf '%s' "$SUMMARY" | tr '\n' ' ' | cut -c1-900)"
exit 1
