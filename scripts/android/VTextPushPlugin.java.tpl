package __APP_ID__;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.onesignal.OneSignal;

import org.json.JSONObject;

/**
 * Snapme's second push route: OneSignal. This file (and VTextApp) is only added to the build when OneSignal is part of it
 * (scripts/onesignal-app-id.txt / VT_ONESIGNAL_APP_ID); when it does not compile, the build script leaves it out and builds the app without it.
 * The notifications themselves are SENT by the free Cloudflare Worker (push-worker/vtext-push-worker.js); this plugin only
 * registers the phone and shows what OneSignal delivers, also when the app is closed. Nothing runs in the background by itself.
 *
 * The web page talks to this plugin as "VTextPush":
 *   login({uid})   the signed-in person's Firebase user id becomes the OneSignal "external id" (the sender addresses people by it)
 *   logout()       this phone stops receiving that person's messages
 *   optIn() / optOut()   "Show notifications" switch
 *   status()       { ready, id, optedIn, permission, err }
 *   takeChat()     the chat id of a notification that was tapped while the page was not ready (cold start), then forgets it
 *   event "open"   { chat }  a notification was tapped
 */
@CapacitorPlugin(name = "VTextPush")
public class VTextPushPlugin extends Plugin {

    static final String ONESIGNAL_APP_ID = "__ONESIGNAL_APP_ID__";

    private static boolean booted = false;
    private static String bootErr = "";
    private static boolean visible = false;
    private static String pendingChat = "";
    private static VTextPushPlugin live = null;

    /** The channel the notifications use (the same one the app's own notifications use: Snapme chime, high importance). Created here so it exists before the page ever ran. */
    private static void ensureChannel(Context c) {
        try {
            if (Build.VERSION.SDK_INT < 26) return;
            NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null || nm.getNotificationChannel("snapme_msgs") != null) return;
            NotificationChannel ch = new NotificationChannel("snapme_msgs", "Messages", NotificationManager.IMPORTANCE_HIGH);
            ch.enableVibration(true);
            String pkg = c.getPackageName();
            int raw = c.getResources().getIdentifier("snapme_chime", "raw", pkg);
            if (raw != 0) {
                AudioAttributes aa = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build();
                ch.setSound(Uri.parse("android.resource://" + pkg + "/" + raw), aa);
            }
            nm.createNotificationChannel(ch);
        } catch (Throwable t) {
            // the channel is created by the page as well
        }
    }

    /** Called by VTextApp.onCreate (every start of the app process, also when a push starts it) and by MainActivity.onCreate. */
    public static synchronized void boot(Context context) {
        if (booted) return;
        try {
            ensureChannel(context.getApplicationContext());
            OneSignal.initWithContext(context.getApplicationContext(), ONESIGNAL_APP_ID);
            // a tapped notification opens its chat
            OneSignal.getNotifications().addClickListener(event -> {
                try {
                    JSONObject data = event.getNotification().getAdditionalData();
                    String chat = data == null ? "" : data.optString("chat", "");
                    if (chat.length() > 0) {
                        pendingChat = chat;
                        VTextPushPlugin p = live;
                        if (p != null) p.fireOpen(chat);
                    }
                } catch (Exception e) {
                    // ignore
                }
            });
            // while VText is on the screen the chat list already shows the new message: no notification on top of it
            OneSignal.getNotifications().addForegroundLifecycleListener(event -> {
                if (visible) event.preventDefault();
            });
            booted = true;
        } catch (Throwable t) {
            booted = false;
            String m = String.valueOf(t);
            bootErr = m.length() > 120 ? m.substring(0, 120) : m;
        }
    }

    public static void setVisible(boolean v) {
        visible = v;
    }

    @Override
    public void load() {
        live = this;
    }

    private void fireOpen(String chat) {
        JSObject o = new JSObject();
        o.put("chat", chat);
        notifyListeners("open", o, true);
    }

    @PluginMethod
    public void login(PluginCall call) {
        String uid = call.getString("uid", "");
        if (uid == null || uid.length() == 0) {
            call.reject("uid is needed");
            return;
        }
        try {
            OneSignal.login(uid);
            call.resolve();
        } catch (Throwable t) {
            call.reject("OneSignal login failed");
        }
    }

    @PluginMethod
    public void logout(PluginCall call) {
        try {
            OneSignal.logout();
        } catch (Throwable t) {
            // ignore
        }
        call.resolve();
    }

    @PluginMethod
    public void optIn(PluginCall call) {
        try {
            OneSignal.getUser().getPushSubscription().optIn();
        } catch (Throwable t) {
            // ignore
        }
        call.resolve();
    }

    @PluginMethod
    public void optOut(PluginCall call) {
        try {
            OneSignal.getUser().getPushSubscription().optOut();
        } catch (Throwable t) {
            // ignore
        }
        call.resolve();
    }

    @PluginMethod
    public void status(PluginCall call) {
        JSObject r = new JSObject();
        r.put("ready", booted);
        String id = "";
        boolean opted = false;
        try {
            String x = OneSignal.getUser().getPushSubscription().getId();
            if (x != null) id = x;
            Boolean o = OneSignal.getUser().getPushSubscription().getOptedIn();
            opted = o != null && o;
        } catch (Throwable t) {
            // ignore
        }
        boolean perm = false;
        try {
            perm = OneSignal.getNotifications().getPermission();
        } catch (Throwable t) {
            // ignore
        }
        r.put("id", id);
        r.put("optedIn", opted);
        r.put("permission", perm);
        r.put("err", bootErr);
        call.resolve(r);
    }

    @PluginMethod
    public void takeChat(PluginCall call) {
        JSObject r = new JSObject();
        r.put("chat", pendingChat);
        pendingChat = "";
        call.resolve(r);
    }
}
