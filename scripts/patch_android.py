"""Patches the freshly generated Capacitor Android project (run from the repo root, after `npx cap add android`).

Environment:
  VERSION_CODE   integer, becomes versionCode (and versionName 1.0.<n>)
  VT_NATIVE      "full" (default) = background service + keep-alive MainActivity + battery helper
                 "none"           = plain Capacitor project (only permissions, version, signing)
  VT_PUSH_PLUGIN "1" (default) = the push-notification plugin is part of this build: add the Firebase settings
                 "0"           = no push plugin: leave all Firebase settings out
  VT_HEADLESS    "1" (default) = the background service can run the VText page in a hidden WebView while the app screen is closed
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
if native == 'full':  # gallery permission (photos / videos): asked once on the "Allow VText to..." screen
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
if headless and 'VTextBoot' not in s:  # starts the background service again after the phone restarts or VText is updated
    rcv = ('        <receiver android:name=".VTextBoot" android:exported="true">\n'
           '            <intent-filter>\n'
           '                <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
           '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>\n'
           '            </intent-filter>\n'
           '        </receiver>\n')
    s = s.replace('</application>', rcv + '    </application>', 1)
# push notifications (Firebase Cloud Messaging): which channel / icon notifications use when the app is closed.
# Harmless when the push plugin or google-services.json is not part of the build.
if push_on and 'default_notification_channel_id' not in s:
    meta = ('        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="messages"/>\n'
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
    for name in names:
        src = pathlib.Path('scripts/android/%s.java.tpl' % name).read_text().replace('__APP_ID__', app_id).replace('__SITE_URL__', site)
        if not headless:
            src = hl_block.sub('', src)
        (jdir / (name + '.java')).write_text(src)
    print('native background helpers installed in', jdir)
    print('hidden background page (keeps listening after the app is swiped away): ' + ('included, site ' + site if headless else 'NOT included'))
print('android project patched (native=%s, versionCode=%s)' % (native, vc))

# ---------------- dark look (matches the neon-dark app: no white flash, dark system bars) ----------------
try:
    vals = root / 'app/src/main/res/values'
    vals.mkdir(parents=True, exist_ok=True)
    cp = vals / 'colors.xml'
    c = cp.read_text() if cp.exists() else '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n'
    if 'vt_bg' not in c:
        c = c.replace('</resources>', '    <color name="vt_bg">#05060B</color>\n</resources>')
        cp.write_text(c)
    sp = vals / 'styles.xml'
    if sp.exists():
        st = sp.read_text()
        st = st.replace('Theme.AppCompat.DayNight.NoActionBar', 'Theme.AppCompat.NoActionBar').replace('Theme.AppCompat.Light.NoActionBar', 'Theme.AppCompat.NoActionBar')
        if 'android:statusBarColor' not in st:
            st = re.sub(r'(<style name="AppTheme\.NoActionBar"[^>]*>)',
                        r'\1\n        <item name="android:windowBackground">@color/vt_bg</item>\n        <item name="android:statusBarColor">@color/vt_bg</item>\n        <item name="android:navigationBarColor">@color/vt_bg</item>\n        <item name="android:windowLightStatusBar">false</item>',
                        st, count=1)
        sp.write_text(st)
    print('dark theme applied')
except Exception as e:  # cosmetic only - never fail the build because of it
    print('WARNING: dark theme not applied:', e)
