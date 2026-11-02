package __APP_ID__;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;

/**
 * "Share to Snapme": the Android Share sheet of the Gallery (or any other app) lists Snapme for photos. MainActivity hands every incoming intent to
 * handle(); the photo is read, turned the right way up, made smaller (at most about 2000 px) and kept as a JPEG until the page asks for it.
 * This file is only added to the build when VT_SHAREIN is on (default); when it does not compile the build script builds again without it.
 *
 * The web page talks to this plugin as "VTextShare":
 *   take()         { data (base64 JPEG, "" when nothing waits), count (how many photos were shared), err ("" or a short English message) }, then forgets it
 *   event "shared" a photo arrived while the page was already running (call take() to get it)
 */
@CapacitorPlugin(name = "VTextShare")
public class VTextSharePlugin extends Plugin {

    private static final int MAX_SIDE = 2000;      // the longest side of the picture handed to the page

    private static String pendingData = "";
    private static String pendingErr = "";
    private static int pendingCount = 0;
    private static VTextSharePlugin live = null;

    @Override
    public void load() {
        live = this;
    }

    /** MainActivity calls this for the first intent and for every new intent. Anything that is not a shared picture is ignored. */
    public static void handle(final Context ctx, final Intent in) {
        try {
            if (ctx == null || in == null) return;
            String action = in.getAction();
            boolean one = Intent.ACTION_SEND.equals(action);
            boolean many = Intent.ACTION_SEND_MULTIPLE.equals(action);
            if (!one && !many) return;
            if (in.getBooleanExtra("vt_share_done", false)) return;   // this very intent was already taken (the screen was recreated)
            String type = in.getType();
            if (type == null || !type.startsWith("image/")) return;
            in.putExtra("vt_share_done", true);

            Uri first = null;
            int count = 1;
            if (one) {
                first = (Uri) in.getParcelableExtra(Intent.EXTRA_STREAM);
            } else {
                ArrayList<Uri> list = in.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (list != null && list.size() > 0) {
                    first = list.get(0);
                    count = list.size();
                }
            }
            if (first == null && in.getClipData() != null && in.getClipData().getItemCount() > 0) {
                first = in.getClipData().getItemAt(0).getUri();
                if (many) count = in.getClipData().getItemCount();
            }
            final Uri uri = first;
            final int n = count;
            if (uri == null) {
                set("", "Snapme could not get this photo from the other app", 1);
                return;
            }
            new Thread(new Runnable() {
                @Override
                public void run() {
                    String data = "";
                    String err = "";
                    try {
                        data = read(ctx, uri);
                    } catch (OutOfMemoryError e) {
                        err = "This photo is too big for Snapme";
                    } catch (Throwable t) {
                        err = "Snapme could not read this photo";
                    }
                    set(data, err, n);
                }
            }, "snapme-share").start();
        } catch (Throwable t) {
            set("", "Snapme could not read this photo", 1);
        }
    }

    private static synchronized void set(String data, String err, int count) {
        pendingData = data;
        pendingErr = err;
        pendingCount = count;
        final VTextSharePlugin p = live;
        if (p != null) {
            new Handler(Looper.getMainLooper()).post(new Runnable() {
                @Override
                public void run() {
                    try {
                        p.notifyListeners("shared", new JSObject(), true);
                    } catch (Throwable t) {
                        // the page asks again with take() when it starts
                    }
                }
            });
        }
    }

    private static int exifRotation(Context ctx, Uri uri, boolean[] flip) {
        if (Build.VERSION.SDK_INT < 24) return 0;
        InputStream is = null;
        try {
            is = ctx.getContentResolver().openInputStream(uri);
            if (is == null) return 0;
            ExifInterface ex = new ExifInterface(is);
            int o = ex.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
            switch (o) {
                case ExifInterface.ORIENTATION_ROTATE_90: return 90;
                case ExifInterface.ORIENTATION_ROTATE_180: return 180;
                case ExifInterface.ORIENTATION_ROTATE_270: return 270;
                case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: flip[0] = true; return 0;
                case ExifInterface.ORIENTATION_FLIP_VERTICAL: flip[0] = true; return 180;
                case ExifInterface.ORIENTATION_TRANSPOSE: flip[0] = true; return 90;
                case ExifInterface.ORIENTATION_TRANSVERSE: flip[0] = true; return 270;
                default: return 0;
            }
        } catch (Throwable t) {
            return 0;
        } finally {
            try {
                if (is != null) is.close();
            } catch (IOException e) {
                // ignore
            }
        }
    }

    /** Reads the picture behind the uri and returns it as a base64 JPEG (no line breaks). */
    static String read(Context ctx, Uri uri) throws IOException {
        ContentResolver cr = ctx.getContentResolver();
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        InputStream is = cr.openInputStream(uri);
        if (is == null) throw new IOException("no stream");
        try {
            BitmapFactory.decodeStream(is, null, o);
        } finally {
            is.close();
        }
        if (o.outWidth <= 0 || o.outHeight <= 0) throw new IOException("not a picture");
        int side = Math.max(o.outWidth, o.outHeight);
        int sample = 1;
        while (side / sample > MAX_SIDE) sample *= 2;
        o.inJustDecodeBounds = false;
        o.inSampleSize = sample;
        Bitmap bm;
        is = cr.openInputStream(uri);
        if (is == null) throw new IOException("no stream");
        try {
            bm = BitmapFactory.decodeStream(is, null, o);
        } finally {
            is.close();
        }
        if (bm == null) throw new IOException("not a picture");

        boolean[] flip = new boolean[1];
        int rot = exifRotation(ctx, uri, flip);
        if (rot != 0 || flip[0]) {
            Matrix m = new Matrix();
            if (flip[0]) m.postScale(-1f, 1f);
            if (rot != 0) m.postRotate(rot);
            Bitmap r = Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
            if (r != bm) bm.recycle();
            bm = r;
        }
        if (bm.hasAlpha()) {   // a transparent picture would turn black as a JPEG: put it on white
            Bitmap w = Bitmap.createBitmap(bm.getWidth(), bm.getHeight(), Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(w);
            c.drawColor(Color.WHITE);
            c.drawBitmap(bm, 0f, 0f, null);
            bm.recycle();
            bm = w;
        }
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        bm.compress(Bitmap.CompressFormat.JPEG, 88, bos);
        bm.recycle();
        return Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP);
    }

    @PluginMethod
    public void take(PluginCall call) {
        JSObject r = new JSObject();
        synchronized (VTextSharePlugin.class) {
            r.put("data", pendingData);
            r.put("err", pendingErr);
            r.put("count", pendingCount);
            pendingData = "";
            pendingErr = "";
            pendingCount = 0;
        }
        call.resolve(r);
    }
}
