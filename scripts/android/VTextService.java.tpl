package __APP_ID__;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import androidx.core.app.NotificationCompat;

/**
 * Keeps the Snapme process in the foreground so Android does not freeze it while the app is in the
 * background. This lets the chat connection keep delivering new-message notifications.
 * (HL = the hidden background page: when the app screen is gone, the service runs the page itself.)
 */
public class VTextService extends Service {
    static final String CHANNEL = "vtext_bg";
    static final int NOTE_ID = 7001;
    /*HL*/
    static final String SITE = "__SITE_URL__";
    private static VTextService inst;
    private VTextHeadless headless;

    /** The app screen is open again: the hidden page is not needed (and must not run twice). */
    static void activityUp() {
        VTextService s = inst;
        if (s != null) s.headlessOff();
    }

    /** The app screen is gone (swiped away, backed out or closed by Android): the hidden page takes over. */
    static void activityGone() {
        VTextService s = inst;
        if (s != null) s.headlessOn();
    }

    private void headlessOn() {
        if (headless != null || SITE.length() == 0) return;
        if (!getSharedPreferences("vtext", MODE_PRIVATE).getBoolean("bg", false)) return;
        try {
            headless = new VTextHeadless(this, SITE);
            headless.start();
        } catch (Throwable t) {
            headless = null;
        }
    }

    private void headlessOff() {
        if (headless == null) return;
        try {
            headless.stop();
        } catch (Throwable t) {
            // ignore
        }
        headless = null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        inst = this;
    }
    /*END_HL*/

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationChannel ch = new NotificationChannel(CHANNEL, "Snapme running in background", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                ch.setSound(null, null);
                NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
                if (nm != null) nm.createNotificationChannel(ch);
            }
            int icon = getResources().getIdentifier("ic_stat_vtext", "drawable", getPackageName());
            if (icon == 0) icon = getApplicationInfo().icon;
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            PendingIntent pi = null;
            if (launch != null) {
                pi = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            }
            NotificationCompat.Builder b = new NotificationCompat.Builder(this, CHANNEL)
                    .setSmallIcon(icon)
                    .setContentTitle("Snapme")
                    .setContentText("Running in the background so you can get messages")
                    .setOngoing(true)
                    .setShowWhen(false)
                    .setPriority(NotificationCompat.PRIORITY_MIN)
                    .setCategory(NotificationCompat.CATEGORY_SERVICE);
            if (pi != null) b.setContentIntent(pi);
            Notification n = b.build();
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(NOTE_ID, n);
            }
        } catch (Exception e) {
            stopSelf();
            return START_NOT_STICKY;
        }
        /*HL*/
        // started with no app screen (after a restart, or Android restarted the service): run the hidden page
        if (!MainActivity.isUp()) headlessOn();
        /*END_HL*/
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        /*HL*/
        headlessOff();
        inst = null;
        /*END_HL*/
        stopForeground(true);
        super.onDestroy();
    }
}
