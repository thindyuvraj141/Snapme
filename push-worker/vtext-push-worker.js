/* Snapme push sender  -  a free Cloudflare Worker that sends the push notifications through OneSignal.
 *
 * WHY IT EXISTS: a push needs a secret key (the OneSignal REST key) and the app must never contain a secret. This Worker keeps the key.
 * Free Firebase cannot run such a server, Cloudflare Workers can (free plan, no card).
 *
 * HOW IT WORKS: after something happened in the app, the app of the person who DID it (the sender) calls this Worker with its Firebase login:
 *   { t: <Firebase ID token>, k: 'chat',  chat: <chat id> }              a message was sent
 *   { t: <token>,             k: 'post',  post: <post id> }              a friend snap was posted
 *   { t: <token>,             k: 'req',   to: <uid> }                    a friend request was sent
 *   { t: <token>,             k: 'nf',    to: <uid>, id: <notification id> }   a like / comment / accepted request (the notification document)
 *   { t: <token>,             test: true }                               "send a test notification to my phone"
 * For every call the Worker
 *   1. checks the Firebase ID token (on Google's public keys): it knows WHO is calling,
 *   2. reads the document of the event from Firestore (service account) and checks that the caller really did it a moment ago,
 *   3. looks at the receivers' settings (phone registered with OneSignal, notifications on, chat muted / locked, receiver blocked the caller),
 *   4. asks OneSignal to deliver one notification to those people (they are addressed by their Firebase user id = OneSignal "external id").
 * It answers { ok, sent, miss }:  miss = receivers whose phone is NOT registered with OneSignal; the sender's app then uses the Expo route for
 * exactly those people (so nobody gets two notifications, and nobody who has only Expo is left out). Nothing is stored in the Worker.
 *
 * Secrets (Cloudflare > your Worker > Settings > Variables and Secrets, type "Secret"):
 *   ONESIGNAL_REST_KEY   the REST API Key of your OneSignal app (OneSignal > Settings > Keys & IDs)
 *   FIREBASE_SA          the whole content of the Firebase service-account JSON file (Firebase console > Project settings > Service accounts)
 * Optional plain variables:  ONESIGNAL_APP_ID, FIREBASE_PROJECT, ALLOWED_ORIGIN (default *), SHOW_TEXT ("false" = only "New message").
 * Free plan limits that matter: 100,000 requests a day, 50 outgoing calls per request (this Worker needs 4 to 8).
 */
const DEFAULT_APP_ID = 'eaee4d46-0219-44e9-ac45-10b45587223e';
const JWKS_URL = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
const ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const MAX_RECIPIENTS = 200;         // people notified by one call (a snap of somebody with very many friends)
const MAX_AGE_MS = 180000;          // a push is only sent for something that happened at most 3 minutes ago
const NF_REPEAT_MS = 600000;        // the same like / comment / accept notifies once in 10 minutes (un-like + like again does not spam)
const CHANNEL = 'snapme_msgs';      // the Android notification channel with the Snapme chime (created by the app)

class HttpErr extends Error { constructor(status, msg) { super(msg); this.status = status; this.expose = true; } }

const enc = new TextEncoder();
const b64ToBytes = s => { s = String(s).replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '='; const bin = atob(s); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; };
const bytesToB64u = b => { const u = new Uint8Array(b); let s = ''; for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
const jpart = s => JSON.parse(new TextDecoder().decode(b64ToBytes(s)));

/* ---------- 1. who is calling: verify the Firebase ID token ---------- */
let jwks = { keys: null, at: 0 };
async function getJwks(force) {
  if (!force && jwks.keys && Date.now() - jwks.at < 3600e3) return jwks.keys;
  const r = await fetch(JWKS_URL);
  if (!r.ok) throw new HttpErr(502, 'Could not load the Google signing keys');
  const j = await r.json();
  jwks = { keys: j.keys || [], at: Date.now() };
  return jwks.keys;
}
async function verifyIdToken(token, project) {
  const p = String(token || '').split('.');
  if (p.length !== 3) throw new HttpErr(401, 'Please log in again');
  let h, c;
  try { h = jpart(p[0]); c = jpart(p[1]); } catch (e) { throw new HttpErr(401, 'Please log in again'); }
  if (h.alg !== 'RS256' || !h.kid) throw new HttpErr(401, 'Please log in again');
  let jwk = (await getJwks(false)).find(k => k.kid === h.kid);
  if (!jwk) jwk = (await getJwks(true)).find(k => k.kid === h.kid);          // Google rotated its keys
  if (!jwk) throw new HttpErr(401, 'Please log in again');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64ToBytes(p[2]), enc.encode(p[0] + '.' + p[1]));
  if (!ok) throw new HttpErr(401, 'Please log in again');
  const now = Math.floor(Date.now() / 1000);
  if (c.aud !== project || c.iss !== 'https://securetoken.google.com/' + project) throw new HttpErr(401, 'This login belongs to another Firebase project');
  if (!(c.exp > now) || c.iat > now + 300) throw new HttpErr(401, 'Your login has expired, please try again');
  if (typeof c.sub !== 'string' || !c.sub || c.sub.length > 128) throw new HttpErr(401, 'Please log in again');
  return c.sub;
}

/* ---------- 2. read Firestore with the service account ---------- */
let gTok = { v: null, exp: 0 };
async function googleToken(sa) {
  if (gTok.v && Date.now() < gTok.exp - 300e3) return gTok.v;
  const now = Math.floor(Date.now() / 1000), uri = sa.token_uri || 'https://oauth2.googleapis.com/token';
  const head = bytesToB64u(enc.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claim = bytesToB64u(enc.encode(JSON.stringify({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/datastore', aud: uri, iat: now, exp: now + 3600 })));
  let key;
  try { key = await crypto.subtle.importKey('pkcs8', b64ToBytes(String(sa.private_key).replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '')), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']); }
  catch (e) { throw new HttpErr(500, 'The private key inside FIREBASE_SA is not valid. Paste the whole JSON file again.'); }
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(head + '.' + claim));
  const r = await fetch(uri, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: head + '.' + claim + '.' + bytesToB64u(sig) }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new HttpErr(500, 'Google did not accept the service account (' + (j.error_description || j.error || r.status) + ')');
  gTok = { v: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000 };
  return gTok.v;
}
function dec(v) {
  if (!v || typeof v !== 'object') return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return Date.parse(v.timestampValue);
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(dec);
  if ('mapValue' in v) return decFields(v.mapValue.fields || {});
  return null;
}
function decFields(f) { const o = {}; for (const k of Object.keys(f || {})) o[k] = dec(f[k]); return o; }
/* reads many documents in ONE call (up to 100); returns { 'path': {fields} } (missing documents are left out) */
async function fsBatch(project, tok, paths) {
  const out = {};
  const base = 'projects/' + project + '/databases/(default)/documents';
  for (let i = 0; i < paths.length; i += 100) {
    const r = await fetch('https://firestore.googleapis.com/v1/' + base + ':batchGet', {
      method: 'POST', headers: { Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
      body: JSON.stringify({ documents: paths.slice(i, i + 100).map(p => base + '/' + p) }) });
    if (!r.ok) throw new HttpErr(502, 'Firestore said ' + r.status + (r.status === 403 ? ' (the service account may not read Firestore)' : ''));
    (await r.json()).forEach(x => { if (x.found) out[x.found.name.slice(base.length + 1)] = decFields(x.found.fields || {}); });
  }
  return out;
}

/* ---------- 3. the text of the notifications ---------- */
const clean = (s, n) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, n);
const firstName = s => clean(s, 40).split(' ')[0] || 'Someone';
function chatText(chat, uid, showText) {
  const last = clean(chat.last, 140);
  const body = showText && last ? last : 'New message';
  if (chat.type === 'group') return { title: clean(chat.name, 60) || 'Group', body: firstName(chat.names && chat.names[uid]) + ': ' + body };
  return { title: clean(chat.names && chat.names[uid], 60) || 'Snapme', body };
}
function nfText(d, showText) {
  const n = clean(d.n, 60) || (d.un ? '@' + clean(d.un, 30) : 'Someone');
  if (d.t === 'like') return { title: 'Snapme', body: n + (d.r === 'h' ? ' loved' : ' liked') + ' your snap' };
  if (d.t === 'comment') return { title: 'Snapme', body: n + ' commented on your snap' + (showText && d.x ? ': ' + clean(d.x, 100) : '') };
  if (d.t === 'accept') return { title: 'Snapme', body: n + ' accepted your friend request' };
  return null;
}

/* ---------- 4. OneSignal ---------- */
async function oneSignal(env, ids, title, body, data, collapse) {
  const payload = { app_id: env.ONESIGNAL_APP_ID || DEFAULT_APP_ID, target_channel: 'push', include_aliases: { external_id: ids },
    headings: { en: title }, contents: { en: body }, priority: 10, ttl: 86400, small_icon: 'ic_stat_vtext', existing_android_channel_id: CHANNEL };
  if (data && data.chat) { payload.data = data; }
  if (collapse) payload.collapse_id = String(collapse).slice(0, 60);
  const r = await fetch('https://api.onesignal.com/notifications', { method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8', Authorization: 'Key ' + env.ONESIGNAL_REST_KEY }, body: JSON.stringify(payload) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const why = Array.isArray(j.errors) ? j.errors.map(e => typeof e === 'string' ? e : JSON.stringify(e)).join('; ') : (j.errors ? JSON.stringify(j.errors) : String(r.status));
    return { ok: false, status: r.status, err: 'OneSignal: ' + why.slice(0, 200) };
  }
  return { ok: true, id: j.id || '', err: (j.errors && !j.id) ? 'OneSignal: ' + JSON.stringify(j.errors).slice(0, 200) : '' };
}

/* ---------- small guards ---------- */
const SEEN = new Map();               // events already handled (best effort, per Worker instance)
const RATE = new Map();               // uid -> {n, t}
function guard(uid) {
  const now = Date.now();
  if (SEEN.size > 2000) for (const [k, t] of SEEN) if (now - t > NF_REPEAT_MS) SEEN.delete(k);
  if (RATE.size > 2000) for (const [k, v] of RATE) if (now - v.t > 60e3) RATE.delete(k);
  const r = RATE.get(uid);
  if (!r || now - r.t > 60e3) RATE.set(uid, { n: 1, t: now });
  else if (++r.n > 90) throw new HttpErr(429, 'Too many requests, please wait a minute');
}
const seen = (key, life) => { const t = SEEN.get(key); return !!t && Date.now() - t < life; };
const fresh = ts => !ts || Date.now() - ts <= MAX_AGE_MS;

/* ---------- who may be notified ----------
   users/<u>/private/push = { os: true|false (this person's phone is registered with OneSignal / has notifications switched off), mut: [chat ids], lck: [chat ids], pn: false (no friend-snap alerts) }
   returns { normal, locked, miss }  (miss = nobody registered a OneSignal phone: the sender app uses Expo for them) */
async function audience(project, tok, uid, rec, opt) {
  const paths = [];
  rec.forEach(u => paths.push('users/' + u + '/private/push', 'blocks/' + u + '_' + uid));
  const info = await fsBatch(project, tok, paths);
  const normal = [], locked = [], miss = [];
  for (const u of rec) {
    const p = info['users/' + u + '/private/push'];
    if (info['blocks/' + u + '_' + uid]) continue;                      // the receiver blocked the caller
    if (!p || typeof p.os !== 'boolean') { miss.push(u); continue; }     // no OneSignal phone (old app, browser, never registered)
    if (p.os !== true) continue;                                         // logged out or notifications switched off
    if (opt.snap && p.pn === false) continue;                            // "New snaps from friends" is off
    if (opt.chat && Array.isArray(p.mut) && p.mut.includes(opt.chat)) continue;   // muted chat
    (opt.chat && Array.isArray(p.lck) && p.lck.includes(opt.chat) ? locked : normal).push(u);
  }
  return { normal, locked, miss };
}
/* sends to the people in a (normal / locked) audience; returns { sent, err } */
async function deliver(env, aud, text, lockedText, data, collapse) {
  let sent = 0, err = '';
  for (const [ids, t] of [[aud.normal, text], [aud.locked, lockedText]]) {
    if (!ids.length || !t) continue;
    const r = await oneSignal(env, ids, t.title, t.body, data, collapse);
    if (r.ok && r.id) sent += ids.length; else if (!r.ok || r.err) err = r.err || err;
  }
  return { sent, err };
}

async function handle(req, env) {
  if (!env.ONESIGNAL_REST_KEY) throw new HttpErr(500, 'The OneSignal REST API key is not set in the Worker (secret ONESIGNAL_REST_KEY).');
  let sa;
  try { sa = JSON.parse(env.FIREBASE_SA || ''); } catch (e) { sa = null; }
  if (!sa || !sa.client_email || !sa.private_key) throw new HttpErr(500, 'The Firebase service account is missing or is not the whole JSON file (secret FIREBASE_SA).');
  const project = env.FIREBASE_PROJECT || sa.project_id;
  const raw = await req.text();
  if (raw.length > 8000) throw new HttpErr(413, 'Request too large');
  let b; try { b = JSON.parse(raw); } catch (e) { throw new HttpErr(400, 'Bad request'); }
  const uid = await verifyIdToken(b.t, project);
  guard(uid);
  const showText = String(env.SHOW_TEXT || 'true').toLowerCase() !== 'false';

  if (b.test === true) {                                              // "Send a test notification to this phone"
    const r = await oneSignal(env, [uid], 'Snapme', 'Test notification: push messages are working ✅', null, '');
    const sent = r.ok && r.id ? 1 : 0, err = r.err || (sent ? '' : 'OneSignal has no active phone for your account yet. Open the app, log in and allow notifications.');
    return { ok: !err, sent, err };
  }

  const kind = String(b.k || 'chat');
  const tok = await googleToken(sa);

  /* ----- a message was sent: the chat document says who wrote the last message and what it was ----- */
  if (kind === 'chat') {
    const chatId = String(b.chat || '');
    if (!ID_RE.test(chatId)) throw new HttpErr(400, 'Bad chat id');
    const doc = (await fsBatch(project, tok, ['chats/' + chatId]))['chats/' + chatId];
    if (!doc || !Array.isArray(doc.members) || !doc.members.includes(uid)) throw new HttpErr(403, 'You are not a member of this chat');
    if (doc.lastFrom !== uid) return { ok: false, wait: true, sent: 0, err: 'The message is not saved yet' };      // the app asks again in a moment
    if (!(doc.lastTs > 0) || !fresh(doc.lastTs)) throw new HttpErr(400, 'This message is too old');
    const key = 'chat/' + chatId + '/' + doc.lastTs;
    if (seen(key, MAX_AGE_MS)) return { ok: true, sent: 0, dup: true };
    SEEN.set(key, Date.now());
    const rec = doc.members.filter(u => typeof u === 'string' && u && u !== uid).slice(0, MAX_RECIPIENTS);
    if (!rec.length) return { ok: true, sent: 0, miss: [] };
    const aud = await audience(project, tok, uid, rec, { chat: chatId });
    const r = await deliver(env, aud, chatText(doc, uid, showText), { title: 'Snapme', body: 'New message' }, { chat: chatId }, chatId);
    return { ok: !r.err, sent: r.sent, miss: aud.miss, err: r.err };
  }

  /* ----- a friend posted a snap ----- */
  if (kind === 'post') {
    const postId = String(b.post || '');
    if (!ID_RE.test(postId)) throw new HttpErr(400, 'Bad post id');
    const p = (await fsBatch(project, tok, ['posts/' + postId]))['posts/' + postId];
    if (!p || p.uid !== uid) throw new HttpErr(404, 'Snap not found');
    if (!fresh(p.ts)) throw new HttpErr(400, 'This snap is too old');
    const key = 'post/' + postId;
    if (seen(key, 3600e3)) return { ok: true, sent: 0, dup: true };
    SEEN.set(key, Date.now());
    const rec = (Array.isArray(p.to) ? p.to : []).filter(u => typeof u === 'string' && ID_RE.test(u) && u !== uid).slice(0, MAX_RECIPIENTS);
    if (!rec.length) return { ok: true, sent: 0, miss: [] };
    const aud = await audience(project, tok, uid, rec, { snap: true });
    const t = { title: clean(p.nm, 40) || 'Snapme', body: 'posted a snap ⚡' };
    const r = await deliver(env, aud, t, null, { chat: 'post:' + postId }, 'post-' + postId);
    return { ok: !r.err, sent: r.sent, miss: aud.miss, err: r.err };
  }

  /* ----- a friend request was sent: requests/<from>_<to> says it ----- */
  if (kind === 'req') {
    const to = String(b.to || '');
    if (!ID_RE.test(to) || to === uid) throw new HttpErr(400, 'Bad receiver');
    const d = (await fsBatch(project, tok, ['requests/' + uid + '_' + to]))['requests/' + uid + '_' + to];
    if (!d || d.from !== uid || d.to !== to || d.status !== 'pending') throw new HttpErr(404, 'Request not found');
    if (!fresh(d.ts)) throw new HttpErr(400, 'This request is too old');
    const key = 'req/' + uid + '_' + to + '/' + (d.ts || 0);
    if (seen(key, NF_REPEAT_MS)) return { ok: true, sent: 0, dup: true };
    SEEN.set(key, Date.now());
    const aud = await audience(project, tok, uid, [to], {});
    const t = { title: 'Snapme', body: firstName(d.fromName) + ' sent you a friend request' };
    const r = await deliver(env, aud, t, null, { chat: 'nf:req' }, 'req-' + uid);
    return { ok: !r.err, sent: r.sent, miss: [], err: r.err };
  }

  /* ----- a like, a comment or an accepted request: the notification document the caller wrote for the receiver ----- */
  if (kind === 'nf') {
    const to = String(b.to || ''), id = String(b.id || '');
    if (!ID_RE.test(to) || to === uid || !ID_RE.test(id)) throw new HttpErr(400, 'Bad notification');
    const path = 'users/' + to + '/notifs/' + id;
    const d = (await fsBatch(project, tok, [path]))[path];
    if (!d || d.from !== uid) throw new HttpErr(404, 'Notification not found');
    if (!fresh(d.ts)) throw new HttpErr(400, 'This notification is too old');
    const key = 'nf/' + to + '/' + id;
    if (seen(key, NF_REPEAT_MS)) return { ok: true, sent: 0, dup: true };
    const t = nfText(d, showText);
    if (!t) throw new HttpErr(400, 'Unknown notification');
    SEEN.set(key, Date.now());
    const aud = await audience(project, tok, uid, [to], {});
    const r = await deliver(env, aud, t, null, { chat: 'nf:' + id }, 'nf-' + id);
    return { ok: !r.err, sent: r.sent, miss: [], err: r.err };
  }
  throw new HttpErr(400, 'Unknown request');
}

const json = (o, st, h) => new Response(JSON.stringify(o), { status: st, headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }, h) });

export default {
  async fetch(req, env) {
    const cors = { 'Access-Control-Allow-Origin': (env && env.ALLOWED_ORIGIN) || '*', 'Access-Control-Allow-Methods': 'POST, GET, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '86400' };
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (req.method === 'GET') return json({ ok: true, service: 'Snapme push sender', oneSignalKey: !!env.ONESIGNAL_REST_KEY, firebaseKey: !!env.FIREBASE_SA }, 200, cors);
    if (req.method !== 'POST') return json({ ok: false, err: 'Use POST' }, 405, cors);
    try { return json(await handle(req, env), 200, cors); }
    catch (e) { return json({ ok: false, err: e && e.expose ? e.message : 'Server error' }, (e && e.status) || 500, cors); }
  }
};
