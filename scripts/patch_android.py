"""Patches the freshly generated Capacitor Android project (run from the repo root, after `npx cap add android`).

Environment:
  VERSION_CODE   integer, becomes versionCode (and versionName 1.0.<n>)
  VT_NATIVE      "full" (default) = Snapme's native helpers (VTextBg plugin: permissions, fingerprint, save to gallery, bar colours; MainActivity that opens
                                    a chat from a notification; the push messaging service VTextFcmService). There is NO background service any more:
                                    no foreground service / "running" notification, no start at boot, no hidden page, no battery-optimisation question.
                 "none"           = plain Capacitor project (only permissions, version, signing)
  VT_PUSH_PLUGIN "1" (default) = the push-notification plugin is part of this build: add the Firebase settings
                 "2"           = same, but without Snapme's own messaging service VTextFcmService (the build script tries this when that file did not
                                 compile): pushes that carry a notification (admin panel) still show when the app is closed
                 "0"           = no push plugin: leave all Firebase settings out
  VT_ONESIGNAL   "1" = OneSignal (the free Cloudflare Worker route, see push-worker/) is part of this build: the OneSignal library, the small plugin
                      VTextPush and VTextApp (starts OneSignal with the app). Needs VT_NATIVE=full. "0" (default) = left out.
                      The build script tries "1" first and builds again with "0" when it does not compile.
  VT_ONESIGNAL_APP_ID  the OneSignal App ID (a public id, NOT the secret REST key). If not set, scripts/onesignal-app-id.txt is used,
                      then the built-in default of this project.
  VT_SHAREIN     "1" (default) = "Share to Snapme": Snapme is listed in the Android Share sheet for photos (Gallery, any other app). Adds two intent filters to the
                      manifest, the plugin VTextShare (reads the photo) and a few lines in MainActivity. Needs VT_NATIVE=full. "0" = left out.
                      The build script builds again with "0" when it does not compile.
  VT_HEADLESS    ignored (the hidden background page was removed; kept so that old workflow files that still set it do not break)
"""
import base64, glob, json, os, pathlib, re, sys

root = pathlib.Path('android')
app_id = json.load(open('capacitor.config.json'))['appId']
native = os.environ.get('VT_NATIVE', 'full')
PUSH_MODE = os.environ.get('VT_PUSH_PLUGIN', '1')
push_on = PUSH_MODE in ('1', '2')
fcm_service = PUSH_MODE == '1'      # "2" = the push plugin and Firebase, but WITHOUT Snapme's own messaging service (used when that service did not build)
try:
    site = (json.load(open('capacitor.config.json')).get('server') or {}).get('url', '') or ''
except Exception:
    site = ''

# ---------------- OneSignal (optional) ----------------
DEFAULT_OS_ID = 'eaee4d46-0219-44e9-ac45-10b45587223e'
def onesignal_id():
    v = os.environ.get('VT_ONESIGNAL_APP_ID', '').strip()
    f = pathlib.Path('scripts/onesignal-app-id.txt')
    if not v and f.exists():
        v = f.read_text().strip()
    if not v:
        v = DEFAULT_OS_ID
    return v if re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', v) else ''
os_on = os.environ.get('VT_ONESIGNAL', '0') == '1'
share_on = native == 'full' and os.environ.get('VT_SHAREIN', '1') == '1'
power_on = native == 'full' and os.environ.get('VT_POWER', '1') == '1'   # "Notifications on time": opens the phone's battery / autostart screens (VTextPowerPlugin)
os_id = onesignal_id() if os_on else ''
if os_on and native != 'full':
    print('push: OneSignal needs the native helpers (VT_NATIVE=full) - left out of this build'); os_on = False
if os_on and not os_id:
    print('push: the OneSignal App ID is not valid (scripts/onesignal-app-id.txt) - OneSignal is left out of this build'); os_on = False

# ---------------- manifest ----------------
mp = root / 'app/src/main/AndroidManifest.xml'
s = mp.read_text()
perms = ['RECORD_AUDIO', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'CAMERA',
         'POST_NOTIFICATIONS', 'USE_BIOMETRIC', 'USE_FINGERPRINT', 'VIBRATE']
add = ''.join('    <uses-permission android:name="android.permission.%s"/>\n' % x for x in perms if ('android.permission.%s"' % x) not in s)
if native == 'full':  # gallery permission (photos / videos): asked once on the "Allow Snapme to..." screen
    for x in ('READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO'):
        if ('android.permission.%s"' % x) not in s:
            add += '    <uses-permission android:name="android.permission.%s"/>\n' % x
    if 'READ_EXTERNAL_STORAGE' not in s:
        add += '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n'
    if power_on and 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS' not in s:  # lets "Notifications on time" ask: Allow Snapme to run in the background? (only when the person taps the button)
        add += '    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>\n'
if 'WRITE_EXTERNAL_STORAGE' not in s:  # only needed on Android 9 and older, to save photos/videos into the gallery
    add += '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n'
for f in ('camera', 'microphone', 'location', 'fingerprint'):
    if 'android.hardware.%s"' % f not in s:
        add += '    <uses-feature android:name="android.hardware.%s" android:required="false"/>\n' % f
s = s.replace('</manifest>', add + '</manifest>')
if 'windowSoftInputMode' not in s:
    s = re.sub(r'<activity\b', '<activity android:windowSoftInputMode="adjustResize"', s, count=1)
# push notifications (Firebase Cloud Messaging): which channel / icon notifications use when the app is closed.
# Harmless when the push plugin or google-services.json is not part of the build.
# Expo Push sends "data only" Android messages. Our own messaging service turns them into notifications and hands everything else
# to Capacitor's push plugin; Capacitor's own service is removed from the merged manifest so only one service receives messages.
if fcm_service and native == 'full' and 'VTextFcmService' not in s:
    if 'xmlns:tools=' not in s:
        s = s.replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
    fcm = ('        <service android:name="com.capacitorjs.plugins.pushnotifications.MessagingService" tools:node="remove"/>\n'
           '        <service android:name=".VTextFcmService" android:exported="false">\n'
           '            <intent-filter android:priority="100">\n'
           '                <action android:name="com.google.firebase.MESSAGING_EVENT"/>\n'
           '            </intent-filter>\n'
           '        </service>\n')
    s = s.replace('</application>', fcm + '    </application>', 1)
if os_on and 'VTextApp' not in s:
    # OneSignal starts together with the app process (also when a push message starts it)
    if re.search(r'<application\b[^>]*android:name=', s):
        print('WARNING: the manifest already has an Application class - OneSignal starts from MainActivity only')
    else:
        s = re.sub(r'<application\b', '<application android:name=".VTextApp"', s, count=1)
if share_on and 'android.intent.action.SEND"' not in s:
    # "Share to Snapme": a photo shared from the Gallery or another app opens Snapme's "Share your snap" page
    flt = ('            <intent-filter>\n'
           '                <action android:name="android.intent.action.SEND"/>\n'
           '                <category android:name="android.intent.category.DEFAULT"/>\n'
           '                <data android:mimeType="image/*"/>\n'
           '            </intent-filter>\n'
           '            <intent-filter>\n'
           '                <action android:name="android.intent.action.SEND_MULTIPLE"/>\n'
           '                <category android:name="android.intent.category.DEFAULT"/>\n'
           '                <data android:mimeType="image/*"/>\n'
           '            </intent-filter>\n')
    s, n_sh = re.subn(r'([ \t]*)</activity>', lambda m: flt + m.group(0), s, count=1)
    if not n_sh:
        print('WARNING: no <activity> in the manifest - Share to Snapme is left out'); share_on = False
if push_on and 'default_notification_channel_id' not in s:
    meta = ('        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="snapme_msgs"/>\n'
            '        <meta-data android:name="com.google.firebase.messaging.default_notification_icon" android:resource="@drawable/ic_stat_vtext"/>\n')
    s = s.replace('</application>', meta + '    </application>', 1)
mp.write_text(s)

# ---------------- Firebase config for push (optional) ----------------
# Put the file you download from Firebase console (Project settings > Your apps > Android > google-services.json)
# into the repo as scripts/google-services.json. Without it the app still builds; push simply stays off.
def firebase_config():
    gs = pathlib.Path('scripts/google-services.json')
    if not gs.exists():
        print('push: scripts/google-services.json not found - push notifications stay off in this build')
        return
    try:
        j = json.loads(gs.read_text())
        pkgs = [c['client_info']['android_client_info']['package_name'] for c in j.get('client', [])]
    except Exception as e:
        print('WARNING: scripts/google-services.json is not valid (%s) - push stays off' % e)
        return
    if app_id not in pkgs:
        print('WARNING: google-services.json is for %s, but this app is %s - push stays off. '
              'In Firebase console add an Android app with the package name %s and download the file again.' % (pkgs or 'no app', app_id, app_id))
        return
    (root / 'app/google-services.json').write_text(gs.read_text())
    # the standard Capacitor template already applies the plugin when the file exists; make sure of it
    rb = root / 'build.gradle'
    if rb.exists():
        r = rb.read_text()
        if 'com.google.gms:google-services' not in r:
            r, n = re.subn(r"(classpath\s+['\"]com\.android\.tools\.build:gradle[^'\"]*['\"])", lambda m: m.group(1) + "\n        classpath 'com.google.gms:google-services:4.4.4'", r, count=1)
            if n: rb.write_text(r)
            else: print('WARNING: could not add the google-services classpath')
    ab = root / 'app/build.gradle'
    a_txt = ab.read_text()
    if 'com.google.gms.google-services' not in a_txt:
        a_txt += "\ntry {\n    def servicesJSON = file('google-services.json')\n    if (servicesJSON.text) {\n        apply plugin: 'com.google.gms.google-services'\n    }\n} catch(Exception e) {\n    logger.info(\"google-services.json not found\")\n}\n"
        ab.write_text(a_txt)
    print('push: Firebase configuration added (project %s)' % j.get('project_info', {}).get('project_id', '?'))
if push_on:
    try:
        firebase_config()
    except Exception as e:  # push is optional - never fail the build because of it
        print('WARNING: push configuration skipped:', e)
else:
    print('push: plugin is not part of this build - Firebase settings left out')

# VTextFcmService extends Firebase's FirebaseMessagingService. Capacitor's push plugin pulls firebase-messaging in with "implementation", which
# is NOT visible to the app module when it compiles Java, so the app needs the library itself (same version as the plugin uses, Capacitor 8: 25.0.1).
# This was the reason why the build with the push plugin failed ("package com.google.firebase.messaging does not exist").
if fcm_service:
    ab = root / 'app/build.gradle'
    a_txt = ab.read_text()
    if 'firebase-messaging' not in a_txt:
        a_txt += ("\n// Snapme: the messaging service (VTextFcmService) is compiled against Firebase Messaging\n"
                  "dependencies {\n"
                  "    implementation \"com.google.firebase:firebase-messaging:${rootProject.ext.has('firebaseMessagingVersion') ? rootProject.ext.firebaseMessagingVersion : '25.0.1'}\"\n"
                  "}\n")
        ab.write_text(a_txt)
        print('push: firebase-messaging added to the app module (needed to compile VTextFcmService)')

# OneSignal library (its Firebase credentials are set once in the OneSignal dashboard; the app's own google-services.json is not used by it)
if os_on:
    ab = root / 'app/build.gradle'
    a_txt = ab.read_text()
    if 'com.onesignal:OneSignal' not in a_txt:
        a_txt, n = re.subn(r'(\ndependencies\s*\{)', lambda m: m.group(1) + "\n    implementation 'com.onesignal:OneSignal:[5.6.1, 5.99.99]'", a_txt, count=1)
        if not n:
            print('ERROR: could not add the OneSignal library to app/build.gradle (OneSignal)'); sys.exit(1)
        ab.write_text(a_txt)
    print('push: OneSignal library added (app id %s...)' % os_id[:8])
else:
    print('push: OneSignal is not part of this build')

# ---------------- version ----------------
vc = os.environ.get('VERSION_CODE')
g = root / 'app/build.gradle'
t = g.read_text()
if vc:
    t, n1 = re.subn(r'versionCode\s*=?\s*\d+', 'versionCode ' + vc, t, count=1)
    t, n2 = re.subn(r'versionName\s*=?\s*"[^"]*"', 'versionName "1.0.' + vc + '"', t, count=1)
    if not (n1 and n2):
        print('WARNING: could not set version in build.gradle (%d/%d)' % (n1, n2))

# ---------------- stable signing key (so a new APK installs over the old one) ----------------
kb = pathlib.Path('scripts/vtext-debug.keystore.b64')
if kb.exists():
    (root / 'app/vtext-debug.keystore').write_bytes(base64.b64decode(kb.read_text().strip()))
    block = ("\n    signingConfigs {\n        debug {\n            storeFile file('vtext-debug.keystore')\n"
             "            storePassword 'android'\n            keyAlias 'androiddebugkey'\n            keyPassword 'android'\n        }\n    }\n")
    if 'vtext-debug.keystore' not in t:
        t, n = re.subn(r'(\nandroid\s*\{)', lambda m: m.group(1) + block, t, count=1)
        if not n:
            print('WARNING: could not add signing config');
else:
    print('WARNING: scripts/vtext-debug.keystore.b64 missing - APKs will be signed with a random key')
if native == 'full' and 'androidx.biometric' not in t:  # fingerprint prompt used by the VTextBg plugin
    t, nb = re.subn(r'(\ndependencies\s*\{)', lambda m: m.group(1) + "\n    implementation 'androidx.biometric:biometric:1.1.0'", t, count=1)
    if not nb:
        print('WARNING: could not add the biometric dependency')
g.write_text(t)

# ---------------- native helpers ----------------
if native == 'full':
    mains = glob.glob(str(root / 'app/src/main/java/**/MainActivity.java'), recursive=True)
    if not mains:
        print('ERROR: MainActivity.java not found'); sys.exit(1)
    jdir = pathlib.Path(mains[0]).parent
    names = ['MainActivity', 'VTextBgPlugin']
    if fcm_service:
        names.append('VTextFcmService')
    if os_on:
        names += ['VTextPushPlugin', 'VTextApp']
    if share_on:
        names.append('VTextSharePlugin')
    if power_on:
        names.append('VTextPowerPlugin')
    # MainActivity: the OneSignal lines are only there when OneSignal is part of the build
    os_lines = {'VT_OS_REG': 'registerPlugin(VTextPushPlugin.class);', 'VT_OS_BOOT': 'VTextPushPlugin.boot(this);',
                'VT_OS_HIDE': 'VTextPushPlugin.setVisible(false);', 'VT_OS_SHOW': 'VTextPushPlugin.setVisible(true);'}
    sh_lines = {'VT_SH_REG': 'registerPlugin(VTextSharePlugin.class);', 'VT_SH_BOOT': 'VTextSharePlugin.handle(this, getIntent());',
                'VT_SH_NEW': 'VTextSharePlugin.handle(this, intent);'}
    pw_lines = {'VT_PW_REG': 'registerPlugin(VTextPowerPlugin.class);'}
    for name in names:
        src = pathlib.Path('scripts/android/%s.java.tpl' % name).read_text().replace('__APP_ID__', app_id).replace('__SITE_URL__', site).replace('__ONESIGNAL_APP_ID__', os_id)
        if name == 'MainActivity':
            for k, v in os_lines.items():
                src = src.replace('/*%s*/' % k, v if os_on else '')
            for k, v in sh_lines.items():
                src = src.replace('/*%s*/' % k, v if share_on else '')
            for k, v in pw_lines.items():
                src = src.replace('/*%s*/' % k, v if power_on else '')
        (jdir / (name + '.java')).write_text(src)
    print('native background helpers installed in', jdir)
    print('no background service, no boot receiver, no hidden page (notifications while the app is closed come from the push service)')
    if os_on:
        print('push: OneSignal plugin (VTextPush) installed')
    if share_on:
        print('share: Share to Snapme installed (photos from the Gallery and other apps; plugin VTextShare)')
    if power_on:
        print('power: Notifications on time installed (opens the battery / autostart settings; plugin VTextPower)')
print('android project patched (native=%s, versionCode=%s)' % (native, vc))

# ---------------- look of the app window (no title bar strip, dark until the page paints, dark system bars) ----------------
# The Android project from `npx cap add android` can come with a theme that has a title bar (ActionBar). That shows up as a
# ~56dp strip at the top of the app with the app name ("Snapme") in it. This part makes the theme deterministic: whatever the
# template looks like, the app themes below have NO title bar and a solid dark window. The page then repaints the window and the
# bars in its own colour (light / dark) through the VTextBg plugin (setBars).
try:
    vals = root / 'app/src/main/res/values'
    vals.mkdir(parents=True, exist_ok=True)
    cp = vals / 'colors.xml'
    c = cp.read_text() if cp.exists() else '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n'
    c = re.sub(r'[ \t]*<color name="vt_bg">[^<]*</color>\n?', '', c)
    c = c.replace('</resources>', '    <color name="vt_bg">#000000</color>\n</resources>')
    cp.write_text(c)

    bars = ('        <item name="windowActionBar">false</item>\n'
            '        <item name="windowNoTitle">true</item>\n'
            '        <item name="android:windowBackground">@color/vt_bg</item>\n'
            '        <item name="android:statusBarColor">@color/vt_bg</item>\n'
            '        <item name="android:navigationBarColor">@color/vt_bg</item>\n'
            '        <item name="android:windowLightStatusBar">false</item>\n')
    base = '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n'
    sp = vals / 'styles.xml'
    st = sp.read_text() if sp.exists() else base

    def put_style(txt, name, parent, body):
        block = '    <style name="%s" parent="%s">\n%s    </style>' % (name, parent, body)
        pat = re.compile(r'[ \t]*<style\s+name="%s"[^>]*?(?:/>|>.*?</style>)' % re.escape(name), re.S)
        if pat.search(txt):
            return pat.sub(lambda m: block, txt, count=1)
        return txt.replace('</resources>', block + '\n</resources>')

    st = put_style(st, 'AppTheme', 'Theme.AppCompat.NoActionBar', bars)
    st = put_style(st, 'AppTheme.NoActionBar', 'AppTheme', '        <item name="android:background">@null</item>\n')
    # launch theme (shown while the app starts): keep the template's one, but make its colours dark too
    m = re.search(r'<style\s+name="AppTheme\.NoActionBarLaunch"\s+parent="([^"]*)"[^>]*>(.*?)</style>', st, re.S)
    if m:
        body = m.group(2).rstrip()
        if 'SplashScreen' in m.group(1):
            if 'windowSplashScreenBackground' not in body:
                body += '\n        <item name="windowSplashScreenBackground">@color/vt_bg</item>'
            if 'postSplashScreenTheme' not in body:
                body += '\n        <item name="postSplashScreenTheme">@style/AppTheme.NoActionBar</item>'
        else:
            body = re.sub(r'[ \t]*<item name="android:windowBackground">[^<]*</item>\n?', '', body)
            body += '\n        <item name="android:windowBackground">@color/vt_bg</item>\n        <item name="windowActionBar">false</item>\n        <item name="windowNoTitle">true</item>'
        st = st[:m.start(2)] + body + '\n    ' + st[m.end(2):]
    else:
        st = put_style(st, 'AppTheme.NoActionBarLaunch', 'AppTheme.NoActionBar', '        <item name="android:windowBackground">@color/vt_bg</item>\n')
    sp.write_text(st)

    # the manifest must use those themes (some templates point the activity at a theme with an ActionBar)
    s2 = mp.read_text()
    if re.search(r'<application\b[^>]*android:theme=', s2) is None:
        s2 = re.sub(r'<application\b', '<application android:theme="@style/AppTheme"', s2, count=1)
    s2 = re.sub(r'(<activity\b[^>]*?android:theme=")@style/[A-Za-z0-9_.]*(")',
                lambda m: m.group(1) + ('@style/AppTheme.NoActionBarLaunch' if 'Launch' in m.group(0) else '@style/AppTheme.NoActionBar') + m.group(2), s2, count=1)
    mp.write_text(s2)
    print('window theme applied (no title bar, dark window)')
except Exception as e:  # cosmetic only - never fail the build because of it
    print('WARNING: window theme not applied:', e)
