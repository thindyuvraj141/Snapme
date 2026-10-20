// VText service worker: the app is cached and only changes when the user taps Settings > App update.
const CACHE = 'vtext-shell';
const FILES = ['./', 'index.html', 'offline.html', 'logo.svg', 'manifest.json'];
const reqOf = u => new Request(new URL(u, self.registration.scope).href);
// The Firebase scripts come from Google's server. Keep a copy on the phone so VText also opens (and shows the saved chats) without internet.
const CDN = ['app', 'auth', 'firestore'].map(n => 'https://www.gstatic.com/firebasejs/10.12.2/firebase-' + n + '-compat.js');
const isCdn = u => u.origin === 'https://www.gstatic.com' && u.pathname.indexOf('/firebasejs/') === 0;
// Fetch a Firebase script and keep a copy. If the server does not allow a normal (CORS) request the plain script request is kept instead.
async function getCdn(c, url, req) {
  try {
    const res = await fetch(url, { mode: 'cors' });
    if (res.ok) c.put(url, res.clone()).catch(() => {});
    return res;
  } catch (x) {
    const res = await fetch(req || new Request(url, { mode: 'no-cors' }));
    if (res.type === 'opaque') c.put(url, res.clone()).catch(() => {});
    return res;
  }
}
async function keepCdn(c, url) {
  try { if (!(await c.match(url))) await getCdn(c, url); } catch (x) {}
}

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    if (!(await c.keys()).length) {
      for (const u of FILES) { try { await c.add(reqOf(u)); } catch (x) {} }
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', e => e.waitUntil((async () => {
  await self.clients.claim();
  const c = await caches.open(CACHE);
  for (const u of CDN) await keepCdn(c, u);
})()));

self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method === 'GET' && isCdn(u)) {
    e.respondWith((async () => {
      const c = await caches.open(CACHE);
      const hit = await c.match(r.url);
      return hit || getCdn(c, r.url, r);
    })());
    return;
  }
  if (r.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('/version.json')) return;
  e.respondWith((async () => {
    const hit = await caches.match(r, { ignoreSearch: true });
    return hit || fetch(r);
  })());
});

self.addEventListener('message', e => {
  if (e.data !== 'update') return;
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    let ok = 0;
    for (const u of CDN) await keepCdn(c, u);
    for (const u of FILES) {
      try {
        const base = reqOf(u).url;
        const res = await fetch(base + (base.includes('?') ? '&' : '?') + 't=' + Date.now(), { cache: 'reload' });
        if (res.ok) { await c.put(reqOf(u), res); ok++; }
      } catch (x) {}
    }
    const target = e.source || (await self.clients.matchAll())[0];
    if (target) target.postMessage(ok ? 'updated' : 'failed');
  })());
});
