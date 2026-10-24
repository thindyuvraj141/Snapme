package __APP_ID__;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import androidx.core.content.ContextCompat;

/** After the phone restarts (or Snapme is updated) the background service is started again, if it was on. */
public class VTextBoot extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            String a = intent == null ? null : intent.getAction();
            if (!Intent.ACTION_BOOT_COMPLETED.equals(a) && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) return;
            if (!context.getSharedPreferences("vtext", Context.MODE_PRIVATE).getBoolean("bg", false)) return;
            ContextCompat.startForegroundService(context, new Intent(context, VTextService.class));
        } catch (Throwable t) {
            // not allowed right now: the service starts the next time Snapme is opened
        }
    }
}
