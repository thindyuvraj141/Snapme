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

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/** Small local Capacitor plugin: background service, battery optimisation helpers and "save to gallery". */
@CapacitorPlugin(name = "VTextBg")
public class VTextBgPlugin extends Plugin {

    @PluginMethod
    public void start(PluginCall call) {
        try {
            Context c = getContext();
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
