"""Patches the freshly generated Capacitor Android project (run from the repo root, after `npx cap add android`).

Environment:
  VERSION_CODE   integer, becomes versionCode (and versionName 1.0.<n>)
  VT_NATIVE      "full" (default) = background service + keep-alive MainActivity + battery helper
                 "none"           = plain Capacitor project (only permissions, version, signing)
"""
import base64, glob, json, os, pathlib, re, sys

root = pathlib.Path('android')
app_id = json.load(open('capacitor.config.json'))['appId']
native = os.environ.get('VT_NATIVE', 'full')

# ---------------- manifest ----------------
mp = root / 'app/src/main/AndroidManifest.xml'
s = mp.read_text()
perms = ['RECORD_AUDIO', 'MODIFY_AUDIO_SETTINGS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'CAMERA',
         'POST_NOTIFICATIONS', 'USE_BIOMETRIC', 'USE_FINGERPRINT', 'VIBRATE']
if native == 'full':
    perms += ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS']
add = ''.join('    <uses-permission android:name="android.permission.%s"/>\n' % x for x in perms if ('android.permission.%s"' % x) not in s)
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
mp.write_text(s)

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
g.write_text(t)

# ---------------- native helpers ----------------
if native == 'full':
    mains = glob.glob(str(root / 'app/src/main/java/**/MainActivity.java'), recursive=True)
    if not mains:
        print('ERROR: MainActivity.java not found'); sys.exit(1)
    jdir = pathlib.Path(mains[0]).parent
    for name in ('MainActivity', 'VTextService', 'VTextBgPlugin'):
        src = pathlib.Path('scripts/android/%s.java.tpl' % name).read_text().replace('__APP_ID__', app_id)
        (jdir / (name + '.java')).write_text(src)
    print('native background helpers installed in', jdir)
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
