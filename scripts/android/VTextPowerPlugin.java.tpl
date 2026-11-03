package __APP_ID__;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * "Notifications on time": many phones (Xiaomi, Oppo, Realme, Vivo, Samsung, ...) stop an app, or hold its notifications back, after it is swiped away,
 * unless the person allows it in the phone's own settings. This plugin only READS a few phone settings and OPENS the right settings screens for the person.
 * It never changes a setting by itself and it runs nothing in the background.
 * This file is only added to the build when VT_POWER is on (default); when it does not compile the build script builds again without it.
 *
 * The web page talks to this plugin as "VTextPower":
 *   status()          { sdk, brand, model, ignoring (battery restrictions off for Snapme), notif (notifications allowed), channel (importance of "snapme_msgs": 0-5, -1 = not applicable, -2 = not created yet) }
 *   open({what})      what = "ask" (the "Allow Snapme to run in the background?" question), "battery" (the battery optimisation list), "autostart" (the maker's Autostart / background screen,
 *                     or the app page when the phone has none), "notif" (this app's notification settings), "app" (this app's page). Gives { ok, via }.
 */
@CapacitorPlugin(name = "VTextPower")
public class VTextPowerPlugin extends Plugin {

    @PluginMethod
    public void status(PluginCall call) {
        JSObject r = new JSObject();
        try {
            Context c = getContext();
            r.put("sdk", Build.VERSION.SDK_INT);
            r.put("brand", brand());
            r.put("model", Build.MODEL == null ? "" : Build.MODEL);

            boolean ignoring = true;
            try {
                if (Build.VERSION.SDK_INT >= 23) {
                    PowerManager pm = (PowerManager) c.getSystemService(Context.POWER_SERVICE);
                    ignoring = pm != null && pm.isIgnoringBatteryOptimizations(c.getPackageName());
                }
            } catch (Throwable t) {
                ignoring = true;
            }
            r.put("ignoring", ignoring);

            boolean on = true;
            int channel = -1;
            try {
                NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
                if (nm != null) {
                    if (Build.VERSION.SDK_INT >= 24) on = nm.areNotificationsEnabled();
                    if (Build.VERSION.SDK_INT >= 26) {
                        NotificationChannel ch = nm.getNotificationChannel("snapme_msgs");
                        channel = ch == null ? -2 : ch.getImportance();
                    }
                }
            } catch (Throwable t) {
                // keep the defaults
            }
            r.put("notif", on);
            r.put("channel", channel);
        } catch (Throwable t) {
            // the page shows what it got
        }
        call.resolve(r);
    }

    @PluginMethod
    public void open(PluginCall call) {
        String what = call.getString("what", "app");
        if (what == null) what = "app";
        String via = "";
        boolean ok = false;
        try {
            String pkg = getContext().getPackageName();
            if ("ask".equals(what)) {
                if (Build.VERSION.SDK_INT >= 23) {
                    Intent in = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                    in.setData(Uri.parse("package:" + pkg));
                    ok = start(in);
                    via = "ask";
                }
                if (!ok) {
                    what = "battery";
                }
            }
            if ("battery".equals(what) && !ok) {
                if (Build.VERSION.SDK_INT >= 23) {
                    ok = start(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
                    via = "battery";
                }
            } else if ("autostart".equals(what)) {
                Intent[] list = autostart(brand());
                for (int i = 0; i < list.length && !ok; i++) {
                    ok = start(list[i]);
                    if (ok) via = "brand";
                }
            } else if ("notif".equals(what)) {
                if (Build.VERSION.SDK_INT >= 26) {
                    Intent in = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS);
                    in.putExtra(Settings.EXTRA_APP_PACKAGE, pkg);
                    ok = start(in);
                    via = "notif";
                }
            }
            if (!ok) {   // the phone has no such screen: this app's own page in Settings, which every phone has
                Intent in = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                in.setData(Uri.parse("package:" + pkg));
                ok = start(in);
                via = "app";
            }
        } catch (Throwable t) {
            ok = false;
        }
        JSObject r = new JSObject();
        r.put("ok", ok);
        r.put("via", via);
        call.resolve(r);
    }

    private boolean start(Intent in) {
        try {
            in.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(in);
            return true;
        } catch (Throwable t) {
            return false;   // no such screen on this phone, or it is not open to other apps
        }
    }

    private static String brand() {
        String b = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.toLowerCase();
        return b.trim();
    }

    private static Intent comp(String pkg, String cls) {
        Intent in = new Intent();
        in.setComponent(new ComponentName(pkg, cls));
        return in;
    }

    /** The screens where the phone makers hide "Autostart" / "Allow background activity". The first one the phone accepts is opened. */
    private static Intent[] autostart(String b) {
        if (b.contains("xiaomi") || b.contains("redmi") || b.contains("poco")) {
            return new Intent[] { comp("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity") };
        }
        if (b.contains("oppo") || b.contains("realme") || b.contains("oneplus")) {
            return new Intent[] {
                comp("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                comp("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                comp("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")
            };
        }
        if (b.contains("vivo") || b.contains("iqoo")) {
            return new Intent[] {
                comp("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                comp("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
                comp("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager")
            };
        }
        if (b.contains("huawei") || b.contains("honor")) {
            return new Intent[] {
                comp("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                comp("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity")
            };
        }
        if (b.contains("samsung")) {
            return new Intent[] { comp("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity") };
        }
        if (b.contains("asus")) {
            return new Intent[] { comp("com.asus.mobilemanager", "com.asus.mobilemanager.powersaver.PowerSaverSettings") };
        }
        return new Intent[0];
    }
}
