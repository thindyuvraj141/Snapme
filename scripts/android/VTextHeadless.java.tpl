package __APP_ID__;

import android.annotation.SuppressLint;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

/**
 * Runs the VText page in a hidden WebView while the app screen is closed (swiped away, backed out, or closed by Android),
 * so the chat connection keeps listening and new messages still produce a notification. The page is the normal VText page
 * opened with "?bg=1": in that mode it does not show anything, does not mark you online and asks the service to show
 * notifications through window.VTBg.notify().  Everything runs on the main thread.
 */
final class VTextHeadless {
    static final String MSG_CHANNEL = "vtext_msgs";
    private static int counter = 0;

    private final Context ctx;
    private final String site;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private WebView web;
    private boolean on = false;
    private int fails = 0;      // page could not be loaded (offline after a restart ...): try again later
    private int restarts = 0;   // the WebView's renderer process was killed by Android: start a new one

    private String pageUrl() {
        return site + (site.indexOf('?') >= 0 ? "&" : "?") + "bg=1";
    }

    private final Runnable reloadNow = new Runnable() {
        @Override
        public void run() {
            if (!on || web == null) return;
            try {
                web.loadUrl(pageUrl());
            } catch (Throwable t) {
                // ignore
            }
        }
    };

    private final Runnable restart = new Runnable() {
        @Override
        public void run() {
            if (!on) return;
            stop();
            start();
        }
    };

    private void retryLater() {
        if (!on) return;
        fails++;
        handler.removeCallbacks(reloadNow);
        handler.postDelayed(reloadNow, Math.min(300000L, 20000L << Math.min(fails, 4)));
    }

    // Android may throttle a WebView that is not on screen; nudging it keeps the chat connection responsive.
    private final Runnable nudge = new Runnable() {
        @Override
        public void run() {
            if (!on || web == null) return;
            try {
                web.onResume();
                web.resumeTimers();
                web.dispatchWindowVisibilityChanged(View.VISIBLE);
            } catch (Exception e) {
                // ignore
            }
            handler.postDelayed(this, 15000);
        }
    };

    VTextHeadless(Context context, String siteUrl) {
        ctx = context.getApplicationContext();
        site = siteUrl;
    }

    @SuppressLint({"SetJavaScriptEnabled", "JavascriptInterface"})
    void start() {
        if (on) return;
        on = true;
        try {
            web = new WebView(ctx);
            WebSettings s = web.getSettings();
            s.setJavaScriptEnabled(true);
            s.setDomStorageEnabled(true);
            s.setDatabaseEnabled(true);
            s.setAllowFileAccess(false);
            s.setAllowContentAccess(false);
            s.setMediaPlaybackRequiresUserGesture(true);
            web.addJavascriptInterface(new Bridge(ctx), "VTBg");
            web.setWebViewClient(new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    // this hidden page may only ever show VText itself
                    return !request.getUrl().toString().startsWith(site);
                }

                @Override
                public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                    if (request != null && request.isForMainFrame()) retryLater();
                }

                @Override
                public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse errorResponse) {
                    if (request != null && request.isForMainFrame() && errorResponse != null && errorResponse.getStatusCode() >= 400) retryLater();
                }

                @Override
                public void onPageFinished(WebView view, String url) {
                    fails = 0;
                }

                // Android can kill the WebView's renderer process while the app is in the background; without this the whole app would crash
                @Override
                public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                    restarts++;
                    handler.removeCallbacks(restart);
                    handler.postDelayed(restart, Math.min(600000L, 5000L << Math.min(restarts, 7)));
                    return true;
                }
            });
            web.loadUrl(pageUrl());
            handler.postDelayed(nudge, 3000);
        } catch (Throwable t) {
            stop();
        }
    }

    void stop() {
        on = false;
        handler.removeCallbacks(nudge);
        handler.removeCallbacks(reloadNow);
        handler.removeCallbacks(restart);
        try {
            if (web != null) {
                web.stopLoading();
                web.removeJavascriptInterface("VTBg");
                web.loadUrl("about:blank");
                web.destroy();
            }
        } catch (Throwable t) {
            // ignore
        }
        web = null;
    }

    /** What the hidden page may call. */
    static final class Bridge {
        private final Context c;

        Bridge(Context context) {
            c = context;
        }

        @JavascriptInterface
        public void notify(String title, String body, String chat) {
            post(c, title, body, chat);
        }

        /** The hidden page found out the person is logged out (for example another device logged this one out): stop the service. */
        @JavascriptInterface
        public void stop() {
            try {
                c.getSharedPreferences("vtext", Context.MODE_PRIVATE).edit().putBoolean("bg", false).apply();
                c.stopService(new Intent(c, VTextService.class));
            } catch (Throwable t) {
                // ignore
            }
        }
    }

    /** Shows a message notification; tapping it opens the app on that chat. */
    @SuppressLint("MissingPermission")
    static void post(Context c, String title, String body, String chat) {
        try {
            if (!NotificationManagerCompat.from(c).areNotificationsEnabled()) return;
            if (title == null || title.length() == 0) title = "VText";
            if (body == null || body.length() == 0) body = "New message";
            if (title.length() > 120) title = title.substring(0, 120);
            if (body.length() > 400) body = body.substring(0, 400);
            if (chat == null) chat = "";
            if (chat.length() > 128) chat = chat.substring(0, 128);
            NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            String pkg = c.getPackageName();
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(MSG_CHANNEL) == null) {
                NotificationChannel ch = new NotificationChannel(MSG_CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH);
                ch.enableVibration(true);
                int raw = c.getResources().getIdentifier("vtext_msg", "raw", pkg);
                if (raw != 0) {
                    AudioAttributes aa = new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build();
                    ch.setSound(Uri.parse("android.resource://" + pkg + "/" + raw), aa);
                }
                nm.createNotificationChannel(ch);
            }
            int icon = c.getResources().getIdentifier("ic_stat_vtext", "drawable", pkg);
            if (icon == 0) icon = c.getApplicationInfo().icon;
            int id = chat.length() > 0 ? 10000 + (chat.hashCode() & 0xFFFFF) : 30000 + (counter++ % 1000);
            Intent li = c.getPackageManager().getLaunchIntentForPackage(pkg);
            PendingIntent pi = null;
            if (li != null) {
                li.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                li.putExtra("vt_chat", chat);
                pi = PendingIntent.getActivity(c, id, li, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            }
            NotificationCompat.Builder b = new NotificationCompat.Builder(c, MSG_CHANNEL)
                    .setSmallIcon(icon)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                    .setDefaults(NotificationCompat.DEFAULT_ALL);
            if (pi != null) b.setContentIntent(pi);
            NotificationManagerCompat.from(c).notify(id, b.build());
        } catch (Throwable t) {
            // a notification that fails must never crash the service
        }
    }
}
