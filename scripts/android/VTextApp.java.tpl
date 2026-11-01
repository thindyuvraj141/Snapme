package __APP_ID__;

import android.app.Application;

/**
 * Only added to the build together with OneSignal (see patch_android.py). OneSignal wants to be started when the app process starts,
 * so that it also works when a push message is what starts the process (the app was swiped away).
 */
public class VTextApp extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        try {
            VTextPushPlugin.boot(this);
        } catch (Throwable t) {
            // never stop the app from starting because of push
        }
    }
}
