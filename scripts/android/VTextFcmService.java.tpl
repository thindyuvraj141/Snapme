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

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import org.json.JSONObject;

import java.util.Map;

/**
 * Receives the Firebase (FCM) messages of the app.
 *
 * Expo Push sends Android messages as "data only" FCM messages (keys title / message / body, no notification part). Android does not
 * show those by itself, so this service turns them into a normal Snapme message notification when the app screen is not in front.
 * Tapping it opens the chat (MainActivity reads "vt_chat").
 * Everything else (normal FCM notification messages, token changes) is passed on to Capacitor's push plugin exactly as before.
 * Only installed when the push plugin is part of the build; it replaces Capacitor's own MessagingService (see patch_android.py).
 */
public class VTextFcmService extends FirebaseMessagingService {
    static final String MSG_CHANNEL = "snapme_msgs";   // the same channel the background page uses, so both look and sound the same
    private static final String CAP = "com.capacitorjs.plugins.pushnotifications.PushNotificationsPlugin";

    @Override
    public void onMessageReceived(RemoteMessage m) {
        super.onMessageReceived(m);
        call("sendRemoteMessage", RemoteMessage.class, m);
        try {
            if (m.getNotification() != null) return;           // a normal notification message: Android / Capacitor handle it
            Map<String, String> d = m.getData();
            if (d == null || !d.containsKey("body") || !(d.containsKey("title") || d.containsKey("message"))) return;   // not an Expo message
            if (VTextBgPlugin.fg) return;                       // Snapme is open: the page already shows it
            String title = d.get("title"), text = d.get("message"), chat = "";
            try {
                JSONObject j = new JSONObject(d.get("body"));
                chat = j.optString("chat", "");
                if (chat.length() == 0 && j.optJSONObject("data") != null) chat = j.optJSONObject("data").optString("chat", "");
                if (title == null || title.length() == 0) title = j.optString("title", "");
                if (text == null || text.length() == 0) text = j.optString("body", "");
            } catch (Throwable t) {
                // body is not JSON: show title / message as they are
            }
            show(this, title, text, chat);
        } catch (Throwable t) {
            // never crash the messaging service
        }
    }

    @Override
    public void onNewToken(String token) {
        super.onNewToken(token);
        call("onNewToken", String.class, token);
    }

    /** Calls a (static) method of Capacitor's push plugin without compiling against it. */
    private static void call(String name, Class<?> type, Object arg) {
        try {
            java.lang.reflect.Method me = Class.forName(CAP).getDeclaredMethod(name, type);
            me.setAccessible(true);
            me.invoke(null, arg);
        } catch (Throwable t) {
            // the plugin is not loaded (yet): nothing to tell
        }
    }

    @SuppressLint("MissingPermission")
    static void show(Context c, String title, String body, String chat) {
        try {
            if (!NotificationManagerCompat.from(c).areNotificationsEnabled()) return;
            if (title == null || title.length() == 0) title = "Snapme";
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
                int raw = c.getResources().getIdentifier("snapme_chime", "raw", pkg);
                if (raw != 0) {
                    AudioAttributes aa = new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build();
                    ch.setSound(Uri.parse("android.resource://" + pkg + "/" + raw), aa);
                }
                nm.createNotificationChannel(ch);
                nm.deleteNotificationChannel("vtext_msgs");   // the old channel had the old sound, and a channel's sound cannot be changed
            }
            int icon = c.getResources().getIdentifier("ic_stat_vtext", "drawable", pkg);
            if (icon == 0) icon = c.getApplicationInfo().icon;
            // same id as the background page uses for this chat: if both show the message, the second replaces the first
            int id = chat.length() > 0 ? 10000 + (chat.hashCode() & 0xFFFFF) : 30000 + (int) (System.currentTimeMillis() % 1000);
            try {
                NotificationManagerCompat.from(c).cancel(2000000 + (chat.hashCode() & 0xFFFFF));   // the quiet "is typing" notification of this chat is no longer needed
            } catch (Throwable ignore) {
                // ignore
            }
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
                    .setOnlyAlertOnce(true)
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
