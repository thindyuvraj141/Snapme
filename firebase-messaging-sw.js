/* VText: Firebase Cloud Messaging worker for the website / installed web app (browsers only; the Android app does not use it).
   index.html registers it with its own scope ("firebase-cloud-messaging-push-scope"), so it never replaces sw.js. */
self.window = self;                                   // config.js writes to window.*
importScripts(
  'https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js',
  'https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js',
  'config.js'
);
firebase.initializeApp(self.FIREBASE_CONFIG);
const messaging = firebase.messaging();

// The server sends data-only messages to browsers, so the notification is built here.
messaging.onBackgroundMessage(payload => {
  const d = (payload && payload.data) || {};
  return self.registration.showNotification(d.title || 'VText', {
    body: d.body || 'New message',
    icon: 'logo.svg',
    badge: 'logo.svg',
    tag: d.chat || 'vtext',
    renotify: true,
    data: { chat: d.chat || '' }
  });
});

// Tapping it brings VText forward and opens the chat.
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const chat = (event.notification.data && event.notification.data.chat) || '';
  const base = new URL('./', self.location.href).href;
  event.waitUntil((async () => {
    const list = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(base) && 'focus' in c) {
        await c.focus();
        if (chat) c.postMessage({ vtChat: chat });
        return;
      }
    }
    await clients.openWindow(base + (chat ? '#chat=' + encodeURIComponent(chat) : ''));
  })());
});
