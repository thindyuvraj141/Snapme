package __APP_ID__;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.WebView;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean inBackground = false;

    // While the app is in the background, keep nudging the WebView so Android does not throttle
    // or pause its JavaScript timers and network callbacks (needed for background notifications).
    private final Runnable keepAlive = new Runnable() {
        @Override
        public void run() {
            if (!inBackground) return;
            try {
                if (getBridge() != null && getBridge().getWebView() != null) {
                    WebView w = getBridge().getWebView();
                    w.dispatchWindowVisibilityChanged(View.VISIBLE);
                    w.resumeTimers();
                }
            } catch (Exception e) {
                // ignore
            }
            handler.postDelayed(this, 15000);
        }
    };

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(VTextBgPlugin.class);
        super.onCreate(savedInstanceState);
    }

    @Override
    public void onStop() {
        super.onStop();
        inBackground = true;
        handler.removeCallbacks(keepAlive);
        handler.postDelayed(keepAlive, 800);
    }

    @Override
    public void onStart() {
        super.onStart();
        inBackground = false;
        handler.removeCallbacks(keepAlive);
    }
}
