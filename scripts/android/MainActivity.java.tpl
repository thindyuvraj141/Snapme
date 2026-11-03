package __APP_ID__;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.ValueCallback;

import com.getcapacitor.BridgeActivity;

import org.json.JSONObject;

public class MainActivity extends BridgeActivity {

    private final Handler handler = new Handler(Looper.getMainLooper());

    // A notification shown by Snapme (a push message) carries the chat id: open that chat once the page is ready.
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
        /*VT_SH_NEW*/
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(VTextBgPlugin.class);
        /*VT_OS_REG*/
        /*VT_SH_REG*/
        /*VT_PW_REG*/
        super.onCreate(savedInstanceState);
        // Never show the Android title bar (the "Snapme" strip at the top) and keep the window behind the page dark until the page paints.
        try {
            androidx.appcompat.app.ActionBar ab = getSupportActionBar();
            if (ab != null) ab.hide();
            getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(0xFF000000));
        } catch (Throwable t) {
            // cosmetic only
        }
        /*VT_OS_BOOT*/
        handleChatIntent(getIntent());
        /*VT_SH_BOOT*/
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
        /*VT_OS_HIDE*/
        life("pause");
    }

    @Override
    public void onResume() {
        super.onResume();
        VTextBgPlugin.fg = true;
        /*VT_OS_SHOW*/
        life("resume");
    }
}
