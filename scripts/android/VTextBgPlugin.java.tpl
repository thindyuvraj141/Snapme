package __APP_ID__;

import android.Manifest;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.PowerManager;
import android.provider.MediaStore;
import android.provider.Settings;
import android.util.Base64;

import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.concurrent.Executor;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PermissionState;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

/** Small local Capacitor plugin: background service, battery optimisation helpers, fingerprint, "save to gallery" and permission requests. */
@CapacitorPlugin(
        name = "VTextBg",
        permissions = {
                @Permission(alias = "camera", strings = {Manifest.permission.CAMERA}),
                @Permission(alias = "location", strings = {Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION}),
                @Permission(alias = "photos", strings = {"android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VIDEO"}),
                @Permission(alias = "storage", strings = {Manifest.permission.READ_EXTERNAL_STORAGE})
        })
public class VTextBgPlugin extends Plugin {

    /** True while the VText screen is in front (set by MainActivity); the Expo push service shows nothing then. */
    static volatile boolean fg = false;

    // ---------- permissions: camera, gallery (photos / videos), location ----------
    private String stateOf(String alias) {
        try {
            PermissionState s = getPermissionState(alias);
            if (s == PermissionState.GRANTED) return "granted";
            if (s == PermissionState.DENIED) return "denied";
            return "prompt";
        } catch (Exception e) {
            return "denied";
        }
    }

    private String mediaAlias() {
        return Build.VERSION.SDK_INT >= 33 ? "photos" : "storage";
    }

    private JSObject permState() {
        JSObject r = new JSObject();
        r.put("camera", stateOf("camera"));
        r.put("location", stateOf("location"));
        r.put("media", stateOf(mediaAlias()));
        return r;
    }

    /**
     * Push notifications: true when this APK contains the Firebase configuration (google-services.json was added to the
     * repo before the build). Checked with reflection so the app still builds and runs without the Firebase libraries.
     */
    @PluginMethod
    public void pushReady(PluginCall call) {
        boolean ok = false;
        try {
            Class<?> c = Class.forName("com.google.firebase.FirebaseApp");
            Object list = c.getMethod("getApps", Context.class).invoke(null, getContext());
            ok = (list instanceof java.util.List) && !((java.util.List<?>) list).isEmpty();
        } catch (Throwable e) {
            ok = false;
        }
        JSObject r = new JSObject();
        r.put("ready", ok);
        call.resolve(r);
    }

    /** Current state of the three permissions without asking: "granted", "denied" or "prompt". */
    @PluginMethod
    public void permStatus(PluginCall call) {
        call.resolve(permState());
    }

    /** Asks for the permissions given as booleans (camera, location, media; all true by default). */
    @PluginMethod
    public void askPerms(PluginCall call) {
        ArrayList<String> need = new ArrayList<String>();
        if (call.getBoolean("camera", true) && !"granted".equals(stateOf("camera"))) need.add("camera");
        if (call.getBoolean("location", true) && !"granted".equals(stateOf("location"))) need.add("location");
        if (call.getBoolean("media", true) && !"granted".equals(stateOf(mediaAlias()))) need.add(mediaAlias());
        if (need.isEmpty()) {
            call.resolve(permState());
            return;
        }
        try {
            requestPermissionForAliases(need.toArray(new String[0]), call, "permsDone");
        } catch (Exception e) {
            call.resolve(permState());
        }
    }

    @PermissionCallback
    private void permsDone(PluginCall call) {
        call.resolve(permState());
    }

    @PluginMethod
    public void start(PluginCall call) {
        try {
            Context c = getContext();
            c.getSharedPreferences("vtext", Context.MODE_PRIVATE).edit().putBoolean("bg", true).apply();   // remembered for restarts
            ContextCompat.startForegroundService(c, new Intent(c, VTextService.class));
            call.resolve();
        } catch (Exception e) {
            call.reject("Could not start: " + e.getMessage());
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        try {
            Context c = getContext();
            c.getSharedPreferences("vtext", Context.MODE_PRIVATE).edit().putBoolean("bg", false).apply();
            c.stopService(new Intent(c, VTextService.class));
            call.resolve();
        } catch (Exception e) {
            call.reject("Could not stop: " + e.getMessage());
        }
    }

    @PluginMethod
    public void batteryStatus(PluginCall call) {
        JSObject r = new JSObject();
        boolean ignoring = true;
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
                ignoring = pm != null && pm.isIgnoringBatteryOptimizations(getContext().getPackageName());
            }
        } catch (Exception e) {
            ignoring = false;
        }
        r.put("ignoring", ignoring);
        call.resolve(r);
    }

    @PluginMethod
    public void batteryExempt(PluginCall call) {
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getContext().getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            try {
                Intent i = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(i);
                call.resolve();
            } catch (Exception e2) {
                call.reject("Not available on this phone");
            }
        }
    }

    /** Is a fingerprint (or face) sensor with at least one saved fingerprint available? */
    @PluginMethod
    public void bioStatus(PluginCall call) {
        JSObject r = new JSObject();
        try {
            BiometricManager bm = BiometricManager.from(getContext());
            int res = bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG
                    | BiometricManager.Authenticators.BIOMETRIC_WEAK);
            r.put("available", res == BiometricManager.BIOMETRIC_SUCCESS);
            r.put("code", res);
        } catch (Exception e) {
            r.put("available", false);
            r.put("code", -1);
        }
        call.resolve(r);
    }

    /** Shows the system fingerprint prompt. Resolves on success, rejects with "cancelled" or the error text. */
    @PluginMethod
    public void bioAuth(final PluginCall call) {
        final String title = call.getString("title", "VText");
        final String reason = call.getString("reason", "Unlock VText");
        final String cancel = call.getString("cancel", "Use password");
        if (getActivity() == null || !(getActivity() instanceof FragmentActivity)) {
            call.reject("Fingerprint is not available");
            return;
        }
        final FragmentActivity act = (FragmentActivity) getActivity();
        act.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    Executor ex = ContextCompat.getMainExecutor(act);
                    BiometricPrompt prompt = new BiometricPrompt(act, ex, new BiometricPrompt.AuthenticationCallback() {
                        @Override
                        public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                            call.resolve();
                        }

                        @Override
                        public void onAuthenticationError(int errorCode, CharSequence errString) {
                            boolean cancelled = errorCode == BiometricPrompt.ERROR_USER_CANCELED
                                    || errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON
                                    || errorCode == BiometricPrompt.ERROR_CANCELED;
                            call.reject(cancelled ? "cancelled" : String.valueOf(errString));
                        }
                    });
                    BiometricPrompt.PromptInfo info = new BiometricPrompt.PromptInfo.Builder()
                            .setTitle(title)
                            .setSubtitle(reason)
                            .setNegativeButtonText(cancel)
                            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG
                                    | BiometricManager.Authenticators.BIOMETRIC_WEAK)
                            .build();
                    prompt.authenticate(info);
                } catch (Exception e) {
                    call.reject("Fingerprint error: " + e.getMessage());
                }
            }
        });
    }

    /** Paints the window behind the page and the system bars with the page colour (the page calls this when the theme changes). */
    @PluginMethod
    public void setBars(final PluginCall call) {
        final String c = call.getString("color", "#000000");
        final boolean light = Boolean.TRUE.equals(call.getBoolean("light", false));
        try {
            getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        int col = android.graphics.Color.parseColor(c);
                        android.view.Window w = getActivity().getWindow();
                        w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(col));
                        try { w.setStatusBarColor(col); w.setNavigationBarColor(col); } catch (Throwable t) { /* ignored on newer Android */ }
                        androidx.core.view.WindowInsetsControllerCompat ic = androidx.core.view.WindowCompat.getInsetsController(w, w.getDecorView());
                        if (ic != null) { ic.setAppearanceLightStatusBars(light); ic.setAppearanceLightNavigationBars(light); }
                    } catch (Throwable t) {
                        // cosmetic only
                    }
                }
            });
            call.resolve();
        } catch (Throwable t) {
            call.resolve();
        }
    }

    /** Saves a photo / video / voice message / file into the phone's gallery or Downloads (folder "VText"). */
    @PluginMethod
    public void saveMedia(PluginCall call) {
        String b64 = call.getString("data");
        String mime = call.getString("mime", "application/octet-stream");
        String name = call.getString("name", "VText-" + System.currentTimeMillis());
        if (b64 == null || b64.isEmpty()) {
            call.reject("Nothing to save");
            return;
        }
        name = name.replaceAll("[\\\\/:*?\"<>|]", "_");
        try {
            byte[] bytes = Base64.decode(b64, Base64.DEFAULT);
            boolean image = mime.startsWith("image/"), video = mime.startsWith("video/"), audio = mime.startsWith("audio/");
            String dir = image ? Environment.DIRECTORY_PICTURES : video ? Environment.DIRECTORY_MOVIES
                    : audio ? Environment.DIRECTORY_MUSIC : Environment.DIRECTORY_DOWNLOADS;
            Context ctx = getContext();
            String shown;
            if (Build.VERSION.SDK_INT >= 29) {
                ContentResolver cr = ctx.getContentResolver();
                ContentValues v = new ContentValues();
                v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
                v.put(MediaStore.MediaColumns.MIME_TYPE, mime);
                v.put(MediaStore.MediaColumns.RELATIVE_PATH, dir + "/VText");
                v.put(MediaStore.MediaColumns.IS_PENDING, 1);
                Uri base = image ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        : video ? MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        : audio ? MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        : MediaStore.Downloads.EXTERNAL_CONTENT_URI;
                Uri out = cr.insert(base, v);
                if (out == null) throw new IOException("Could not create the file");
                try (OutputStream os = cr.openOutputStream(out)) {
                    if (os == null) throw new IOException("Could not open the file");
                    os.write(bytes);
                }
                ContentValues done = new ContentValues();
                done.put(MediaStore.MediaColumns.IS_PENDING, 0);
                cr.update(out, done, null, null);
                shown = dir + "/VText";
            } else {
                if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                    if (getActivity() != null) {
                        ActivityCompat.requestPermissions(getActivity(), new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, 7011);
                    }
                    call.reject("Allow storage access, then tap Save again");
                    return;
                }
                File folder = new File(Environment.getExternalStoragePublicDirectory(dir), "VText");
                if (!folder.exists() && !folder.mkdirs()) throw new IOException("Could not create the folder");
                File f = new File(folder, name);
                try (FileOutputStream fo = new FileOutputStream(f)) {
                    fo.write(bytes);
                }
                MediaScannerConnection.scanFile(ctx, new String[]{f.getAbsolutePath()}, new String[]{mime}, null);
                shown = dir + "/VText";
            }
            JSObject r = new JSObject();
            r.put("path", shown);
            call.resolve(r);
        } catch (Exception e) {
            call.reject("Could not save: " + e.getMessage());
        }
    }
}
