"""Patches the freshly generated Capacitor Android project (run from the repo root, after `npx cap add android`).

Environment:
  VERSION_CODE   integer, becomes versionCode (and versionName 1.0.<n>)
  VT_NATIVE      "full" (default) = background service + keep-alive MainActivity + battery helper
                 "none"           = plain Capacitor project (only permissions, version, signing)
  VT_PUSH_PLUGIN "1" (default) = the push-notification plugin is part of this build: add the Firebase settings
                 "0"           = no push plugin: leave all Firebase settings out
  VT_HEADLESS    "1" (default) = the background service can run the Snapme page in a hidden WebView while the app screen is closed
                                 (needs VT_NATIVE=full and an app that loads the website, i.e. server.url in capacitor.config.json)
                 "0"           = leave that part out (the build script retries like this if that part does not compile)
"""
import base64, glob, json, os, pathlib, re, sys

root = pathlib.Path('android')
app_id = json.load(open('capacitor.config.json'))['appId']
native = os.environ.get('VT_NATIVE', 'full')
push_on = os.environ.get('VT_PUSH_PLUGIN', '1') == '1'
try:
    site = (json.load(open('capacitor.config.json')).get('server') or {}).get('url', '') or ''
except Exception:
    site = ''
headless = os.environ.get('VT_HEADLESS', '1') == '1' and native == 'full' and site.startswith('https://')

# ---------------- manifest ----------------
mp = root / 'app/src/main/AndroidManifest.xml'
s = mp.read_text()
perms = ['RECORD_AUDIO', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'CAMERA',
         'POST_NOTIFICATIONS', 'USE_BIOMETRIC', 'USE_FINGERPRINT', 'VIBRATE']
if native == 'full':
    perms += ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS']
    if headless:
        perms += ['RECEIVE_BOOT_COMPLETED']
add = ''.join('    <uses-permission android:name="android.permission.%s"/>\n' % x for x in perms if ('android.permission.%s"' % x) not in s)
if native == 'full':  # gallery permission (photos / videos): asked once on the "Allow Snapme to..." screen
    for x in ('READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO'):
        if ('android.permission.%s"' % x) not in s:
            add += '    <uses-permission android:name="android.permission.%s"/>\n' % x
    if 'READ_EXTERNAL_STORAGE' not in s:
        add += '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n'
if 'WRITE_EXTERNAL_STORAGE' not in s:  # only needed on Android 9 and older, to save photos/videos into the gallery
    add += '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n'
for f in ('camera', 'microphone', 'location', 'fingerprint'):
    if 'android.hardware.%s"' % f not in s:
        add += '    <uses-feature android:name="android.hardware.%s" android:required="false"/>\n' % f
s = s.replace('</manifest>', add + '</manifest>')
if 'windowSoftInputMode' not in s:
    s = re.sub(r'<activity\b', '<activity android:windowSoftInputMode="adjustResize"', s, count=1)
if native == 'full' and 'VTextService' not in s:
    svc = ('        <service android:name=".VTextService" android:exported="false" android:foregroundServiceType="specialUse">\n'
           '            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="Keeps the chat connection alive so new message notifications are delivered"/>\n'
           '        </service>\n')
    assert '</application>' in s
    s = s.replace('</application>', svc + '    </application>', 1)
if headless and 'VTextBoot' not in s:  # starts the background service again after the phone restarts or Snapme is updated
    rcv = ('        <receiver android:name=".VTextBoot" android:exported="true">\n'
           '            <intent-filter>\n'
           '                <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
           '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>\n'
           '            </intent-filter>\n'
           '        </receiver>\n')
    s = s.replace('</application>', rcv + '    </application>', 1)
# push notifications (Firebase Cloud Messaging): which channel / icon notifications use when the app is closed.
# Harmless when the push plugin or google-services.json is not part of the build.
# Expo Push sends "data only" Android messages. Our own messaging service turns them into notifications and hands everything else
# to Capacitor's push plugin; Capacitor's own service is removed from the merged manifest so only one service receives messages.
if push_on and native == 'full' and 'VTextFcmService' not in s:
    if 'xmlns:tools=' not in s:
        s = s.replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
    fcm = ('        <service android:name="com.capacitorjs.plugins.pushnotifications.MessagingService" tools:node="remove"/>\n'
           '        <service android:name=".VTextFcmService" android:exported="false">\n'
           '            <intent-filter android:priority="100">\n'
           '                <action android:name="com.google.firebase.MESSAGING_EVENT"/>\n'
           '            </intent-filter>\n'
           '        </service>\n')
    s = s.replace('</application>', fcm + '    </application>', 1)
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
            r, n = re.subn(r"(classpath\s+['\"]com\.android\.tools\.build:gradle[^'\"]*['\"])", lambda m: m.group(1) + "\n        classpath 'com.google.gms:google-services:4.4.2'", r, count=1)
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
    hl_block = re.compile(r'[ \t]*/\*HL\*/.*?/\*END_HL\*/\n', re.S)   # code between /*HL*/ and /*END_HL*/ belongs to the hidden background page
    names = ['MainActivity', 'VTextService', 'VTextBgPlugin'] + (['VTextHeadless', 'VTextBoot'] if headless else [])
    if push_on:
        names.append('VTextFcmService')
    for name in names:
        src = pathlib.Path('scripts/android/%s.java.tpl' % name).read_text().replace('__APP_ID__', app_id).replace('__SITE_URL__', site)
        if not headless:
            src = hl_block.sub('', src)
        (jdir / (name + '.java')).write_text(src)
    print('native background helpers installed in', jdir)
    print('hidden background page (keeps listening after the app is swiped away): ' + ('included, site ' + site if headless else 'NOT included'))
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
