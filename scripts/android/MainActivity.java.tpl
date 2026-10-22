package __APP_ID__;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.ValueCallback;
import android.webkit.WebView;

import com.getcapacitor.BridgeActivity;

import org.json.JSONObject;

public class MainActivity extends BridgeActivity {

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean inBackground = false;
    /*HL*/
    private static volatile boolean up = false;

    /** True while the app screen exists (the background service then does not run the hidden page). */
    static boolean isUp() {
        return up;
    }

    // A notification shown by the background service carries the chat id: open that chat once the page is ready.
    private void handleChatIntent(Intent in) {
        if (in == null) return;
        String chat = in.getStringExtra("vt_chat");
        if (chat == null || chat.length() == 0) return;
        in.removeExtra("vt_chat");
        openChat(chat, 0);
    }

    private void openChat(final String chat, final int tries) {
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    if (getBridge() != null && getBridge().getWebView() != null) {
                        String js = "(function(){if(window.__vtOpen){window.__vtOpen(" + JSONObject.quote(chat) + ");return 1}return 0})()";
                        getBridge().getWebView().evaluateJavascript(js, new ValueCallback<String>() {
                            @Override
                            public void onReceiveValue(String value) {
                                if (!"1".equals(value) && tries < 40) openChat(chat, tries + 1);
                            }
                        });
                        return;
                    }
                } catch (Exception e) {
                    // try again below
                }
                if (tries < 40) openChat(chat, tries + 1);
            }
        }, tries == 0 ? 400 : 500);
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleChatIntent(intent);
    }

    @Override
    public void onDestroy() {
        up = false;
        if (!isChangingConfigurations()) VTextService.activityGone();
        super.onDestroy();
    }
    /*END_HL*/

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
        /*HL*/
        up = true;
        VTextService.activityUp();
        /*END_HL*/
        registerPlugin(VTextBgPlugin.class);
        super.onCreate(savedInstanceState);
        // Never show the Android title bar (the "VText" strip at the top) and keep the window behind the page dark until the page paints.
        try {
            androidx.appcompat.app.ActionBar ab = getSupportActionBar();
            if (ab != null) ab.hide();
            getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(0xFF000000));
        } catch (Throwable t) {
            // cosmetic only
        }
        /*HL*/
        handleChatIntent(getIntent());
        /*END_HL*/
    }

    // Tell the page when the app really goes to the background / comes back (used by the app lock).
    private void life(String state) {
        try {
            if (getBridge() != null && getBridge().getWebView() != null) {
                getBridge().getWebView().evaluateJavascript("window.__vtLife&&window.__vtLife('" + state + "')", null);
            }
        } catch (Exception e) {
            // ignore
        }
    }

    @Override
    public void onPause() {
        super.onPause();
        VTextBgPlugin.fg = false;
        life("pause");
    }

    @Override
    public void onResume() {
        super.onResume();
        VTextBgPlugin.fg = true;
        life("resume");
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
