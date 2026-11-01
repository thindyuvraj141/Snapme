// Tests for push-worker/vtext-push-worker.js  (run:  node push-worker/test.mjs)
import fs from 'node:fs';
import { webcrypto as crypto } from 'node:crypto';
const src = fs.readFileSync(new URL('./vtext-push-worker.js', import.meta.url), 'utf8');
fs.writeFileSync('/tmp/vt_worker_under_test.mjs', src);
let W = (await import('/tmp/vt_worker_under_test.mjs?' + Math.random())).default;
const fresh = async () => { W = (await import('/tmp/vt_worker_under_test.mjs?' + Math.random())).default; };      // a new Worker instance = empty caches

let pass = 0, fail = 0;
const check = (name, cond, extra) => { if (cond) { pass++; console.log('  ok   ' + name); } else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  -> ' + JSON.stringify(extra) : '')); } };

const b64u = b => Buffer.from(b).toString('base64url');
const PROJECT = 'vtext-test';
const alg = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) };
const gKeys = await crypto.subtle.generateKey(alg, true, ['sign', 'verify']);          // plays "Google securetoken"
const gJwk = { ...(await crypto.subtle.exportKey('jwk', gKeys.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' };
const saKeys = await crypto.subtle.generateKey(alg, true, ['sign', 'verify']);         // the service account
const saPem = '-----BEGIN PRIVATE KEY-----\n' + Buffer.from(await crypto.subtle.exportKey('pkcs8', saKeys.privateKey)).toString('base64').replace(/(.{64})/g, '$1\n') + '\n-----END PRIVATE KEY-----\n';
const SA = JSON.stringify({ type: 'service_account', project_id: PROJECT, client_email: 'push@vtext-test.iam.gserviceaccount.com', private_key: saPem, token_uri: 'https://oauth2.googleapis.com/token' });

async function idToken(uid, o = {}) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64u(JSON.stringify({ alg: 'RS256', kid: o.kid || 'k1', typ: 'JWT' }));
  const c = b64u(JSON.stringify({ iss: 'https://securetoken.google.com/' + (o.iss || PROJECT), aud: o.aud || PROJECT, sub: uid, iat: now - 10, exp: o.exp || now + 3000, auth_time: now - 10 }));
  const sig = Buffer.from(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', gKeys.privateKey, new TextEncoder().encode(h + '.' + c)));
  if (o.tamper) sig[5] ^= 1;
  return h + '.' + c + '.' + sig.toString('base64url');
}

// ---------- fake Firestore / OneSignal / Google ----------
const store = new Map();            // 'chats/x' -> plain object
const encV = v => v === null ? { nullValue: null } : typeof v === 'string' ? { stringValue: v } : typeof v === 'boolean' ? { booleanValue: v } : typeof v === 'number' ? { integerValue: String(v) }
  : v instanceof Date ? { timestampValue: v.toISOString() } : Array.isArray(v) ? { arrayValue: { values: v.map(encV) } } : { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, encV(x)])) } };
let calls, osCalls, osReply, tokenHits, jwksHits, fsStatus, saTokenOk;
async function R() { reset(); world(); await fresh(); }
function reset() { calls = []; osCalls = []; osReply = () => ({ status: 200, body: { id: 'n1' } }); tokenHits = 0; jwksHits = 0; fsStatus = 200; saTokenOk = true; }
globalThis.fetch = async (url, init = {}) => {
  url = String(url); calls.push(url);
  const R = (st, body) => new Response(JSON.stringify(body), { status: st, headers: { 'Content-Type': 'application/json' } });
  if (url.includes('securetoken@system')) { jwksHits++; return R(200, { keys: [gJwk] }); }
  if (url === 'https://oauth2.googleapis.com/token') {
    tokenHits++;
    const a = new URLSearchParams(String(init.body)).get('assertion').split('.');
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', saKeys.publicKey, Buffer.from(a[2], 'base64url'), new TextEncoder().encode(a[0] + '.' + a[1]));
    const claim = JSON.parse(Buffer.from(a[1], 'base64url').toString());
    if (!ok || claim.iss !== 'push@vtext-test.iam.gserviceaccount.com' || !claim.scope.includes('datastore')) return R(400, { error: 'invalid_grant' });
    return R(200, { access_token: 'AT1', expires_in: 3600 });
  }
  if (url.includes('firestore.googleapis.com') && url.endsWith(':batchGet')) {
    if (init.headers.Authorization !== 'Bearer AT1') return R(401, {});
    if (fsStatus !== 200) return R(fsStatus, {});
    const base = 'projects/' + PROJECT + '/databases/(default)/documents/';
    const docs = JSON.parse(init.body).documents;
    return R(200, docs.map(n => { const p = n.slice(base.length); return store.has(p) ? { found: { name: n, fields: encV(store.get(p)).mapValue.fields }, readTime: 'x' } : { missing: n, readTime: 'x' }; }));
  }
  if (url === 'https://api.onesignal.com/notifications') {
    const body = JSON.parse(init.body); osCalls.push({ body, auth: init.headers.Authorization });
    const r = osReply(body); return R(r.status, r.body);
  }
  throw new Error('unexpected fetch ' + url);
};

const ENV = { ONESIGNAL_REST_KEY: 'REST-KEY', FIREBASE_SA: SA };
const post = async (body, env = ENV) => { const r = await W.fetch(new Request('https://w.test/', { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) }), env); return { st: r.status, j: await r.json(), h: r.headers }; };
const now = () => new Date();

function world() {
  store.clear();
  // a 1-to-1 chat where Alice just wrote "hello there" (the chat document carries last / lastTs / lastFrom)
  store.set('chats/dm1', { type: 'dm', members: ['A', 'B'], names: { A: 'Alice', B: 'Bob' }, last: 'hello   there', lastTs: now(), lastFrom: 'A' });
  store.set('users/B/private/push', { os: true, mut: [], lck: [] });
  store.set('users/A/private/push', { os: true });
}
const chat = async (u = 'A', id = 'dm1') => post({ t: await idToken(u), k: 'chat', chat: id });

// ================= health / CORS / config =================
await R();
let r = await W.fetch(new Request('https://w.test/', { method: 'GET' }), ENV); let j = await r.json();
check('health: GET tells which secrets are set (not their values)', j.ok === true && j.oneSignalKey === true && j.firebaseKey === true && !JSON.stringify(j).includes('REST-KEY'), j);
r = await W.fetch(new Request('https://w.test/', { method: 'OPTIONS' }), ENV);
check('CORS: preflight answers 204 with allow-origin', r.status === 204 && r.headers.get('Access-Control-Allow-Origin') === '*');
r = await W.fetch(new Request('https://w.test/', { method: 'OPTIONS' }), { ...ENV, ALLOWED_ORIGIN: 'https://x.github.io' });
check('CORS: ALLOWED_ORIGIN can restrict it', r.headers.get('Access-Control-Allow-Origin') === 'https://x.github.io');
let t = await idToken('A');
let x = await post({ t, k: 'chat', chat: 'dm1' }, { FIREBASE_SA: SA });
check('config: missing OneSignal key gives a clear message', x.st === 500 && /ONESIGNAL_REST_KEY/.test(x.j.err), x);
x = await post({ t, k: 'chat', chat: 'dm1' }, { ONESIGNAL_REST_KEY: 'k', FIREBASE_SA: '{"nope":1}' });
check('config: bad service account gives a clear message', x.st === 500 && /FIREBASE_SA/.test(x.j.err), x);
x = await post({ t, k: 'chat', chat: 'dm1' }, { ONESIGNAL_REST_KEY: 'k' });
check('config: missing service account gives a clear message', x.st === 500 && /FIREBASE_SA/.test(x.j.err), x);
check('config: PUT is refused', (await W.fetch(new Request('https://w.test/', { method: 'PUT' }), ENV)).status === 405);

// ================= login checks =================
await R();
x = await post('not json'); check('login: bad JSON is a 400', x.st === 400, x);
x = await post({ t: 'abc', k: 'chat', chat: 'dm1' }); check('login: garbage token is refused', x.st === 401, x);
x = await post({ t: await idToken('A', { aud: 'other-project' }), k: 'chat', chat: 'dm1' }); check('login: token of another Firebase project is refused', x.st === 401, x);
x = await post({ t: await idToken('A', { exp: Math.floor(Date.now() / 1000) - 5 }), k: 'chat', chat: 'dm1' }); check('login: expired token is refused', x.st === 401, x);
x = await post({ t: await idToken('A', { tamper: true }), k: 'chat', chat: 'dm1' }); check('login: a token with a changed signature is refused', x.st === 401, x);
const hits0 = jwksHits;
x = await post({ t: await idToken('A', { kid: 'zzz' }), k: 'chat', chat: 'dm1' }); check('login: unknown key id is refused (keys re-read once)', x.st === 401 && jwksHits === hits0 + 1, [x.st, jwksHits - hits0]);
check('login: nothing was sent to OneSignal for any refused request', osCalls.length === 0);
check('login: the Google keys are cached', jwksHits <= 2, jwksHits);

// ================= a normal 1-to-1 message =================
await R(); tokenHits = 0;
x = await chat();
check('dm: ok, one person notified, nobody missing', x.st === 200 && x.j.ok === true && x.j.sent === 1 && JSON.stringify(x.j.miss) === '[]', x);
check('dm: OneSignal got exactly one call', osCalls.length === 1);
const o = osCalls[0] || { body: {} };
check('dm: sent with the REST key as "Key ..."', osCalls[0] && osCalls[0].auth === 'Key REST-KEY');
check('dm: addressed to the other member only, by external id', JSON.stringify(o.body.include_aliases) === '{"external_id":["B"]}' && o.body.target_channel === 'push' && o.body.app_id === 'eaee4d46-0219-44e9-ac45-10b45587223e', o.body);
check('dm: title is the sender name, body the text (spaces tidied)', o.body.headings.en === 'Alice' && o.body.contents.en === 'hello there', o.body);
check('dm: the chat id travels as data and as collapse id (so a tap opens the chat)', o.body.data.chat === 'dm1' && o.body.collapse_id === 'dm1');
check('dm: high priority, 1 day life, Snapme icon, Snapme chime channel', o.body.priority === 10 && o.body.ttl === 86400 && o.body.small_icon === 'ic_stat_vtext' && o.body.existing_android_channel_id === 'snapme_msgs', o.body);
check('dm: the REST key is never part of the payload', !JSON.stringify(o.body).includes('REST-KEY'));
x = await chat();
check('dm: the same message again is ignored (no second push)', x.j.dup === true && osCalls.length === 1, x);
check('dm: the service-account token was fetched once and is cached', tokenHits === 1, tokenHits);
const nCalls = calls.length; store.get('chats/dm1').lastTs = new Date(Date.now() + 1000);
await chat();
check('dm: a warm request makes only 3 outgoing calls (batchGet x2 + OneSignal)', calls.length - nCalls === 3, calls.slice(nCalls));
store.get('chats/dm1').lastTs = new Date(Date.now() + 2000); store.get('chats/dm1').last = '📷 Photo';
osCalls.length = 0; await chat();
check('dm: a newer message of the same chat is a new push', osCalls.length === 1 && osCalls[0].body.contents.en === '📷 Photo', osCalls.length);

// ================= who is allowed =================
await R();
x = await chat('C'); check('rules: a person who is not in the chat gets 403', x.st === 403, x);
x = await chat('B'); check('rules: a member cannot trigger a push for a message he did not write (asked to wait)', x.j.ok === false && x.j.wait === true && osCalls.length === 0, x);
x = await chat('A', 'nochat'); check('rules: unknown chat gives 403', x.st === 403, x);
store.get('chats/dm1').lastTs = new Date(Date.now() - 10 * 60e3);
x = await chat(); check('rules: a message older than 3 minutes gets no push', x.st === 400, x);
x = await chat('A', '../users'); check('rules: odd ids are refused', x.st === 400, x);
x = await post({ t: await idToken('A'), k: 'chat' }); check('rules: missing ids are refused', x.st === 400, x);
x = await post({ t: await idToken('A'), k: 'zzz' }); check('rules: an unknown kind is refused', x.st === 400, x);
check('rules: no OneSignal call for any refused request', osCalls.length === 0, osCalls.length);

// ================= the other person decides =================
const send = async () => { osCalls.length = 0; store.get('chats/dm1').lastTs = new Date(Date.now() + Math.floor(Math.random() * 1e6)); return chat(); };
await R(); store.set('users/B/private/push', { os: false });
x = await send(); check('prefs: notifications switched off -> nothing sent, and NOT reported as missing (no Expo either)', x.j.sent === 0 && osCalls.length === 0 && x.j.miss.length === 0, x);
await R(); store.delete('users/B/private/push');
x = await send(); check('prefs: never registered with OneSignal -> nothing sent, reported as missing (the sender uses Expo)', x.j.sent === 0 && osCalls.length === 0 && JSON.stringify(x.j.miss) === '["B"]', x);
await R(); store.set('users/B/private/push', { mut: ['dm1'], t: { d: { k: 'x', p: 'android' } } });
x = await send(); check('prefs: a push document without the os flag counts as missing (only a Firebase token)', JSON.stringify(x.j.miss) === '["B"]' && osCalls.length === 0, x);
await R(); store.set('users/B/private/push', { os: true, mut: ['dm1'] });
x = await send(); check('prefs: muted chat -> nothing sent, not missing', x.j.sent === 0 && osCalls.length === 0 && x.j.miss.length === 0, x);
await R(); store.set('blocks/B_A', { by: 'B', to: 'A' });
x = await send(); check('prefs: the receiver blocked the sender -> nothing sent, not missing', x.j.sent === 0 && osCalls.length === 0 && x.j.miss.length === 0, x);
await R(); store.set('blocks/A_B', { by: 'A', to: 'B' });
x = await send(); check('prefs: the SENDER blocked the receiver does not stop it', x.j.sent === 1, x);
await R(); store.set('users/B/private/push', { os: true, lck: ['dm1'] });
x = await send(); check('prefs: locked chat shows no name and no text', x.j.sent === 1 && osCalls[0].body.headings.en === 'Snapme' && osCalls[0].body.contents.en === 'New message', osCalls[0] && osCalls[0].body);
await R();
x = await post({ t: await idToken('A'), k: 'chat', chat: 'dm1' }, { ...ENV, SHOW_TEXT: 'false' });
check('prefs: SHOW_TEXT=false shows only "New message"', osCalls[0] && osCalls[0].body.contents.en === 'New message' && osCalls[0].body.headings.en === 'Alice', osCalls[0] && osCalls[0].body);

// ================= groups =================
await R();
store.set('chats/g1', { type: 'group', name: 'Friends', members: ['A', 'B', 'C', 'D', 'E', 'F'], names: { A: 'Alice Smith' }, last: 'party at 8', lastTs: now(), lastFrom: 'A' });
store.set('users/B/private/push', { os: true }); store.set('users/C/private/push', { os: true, lck: ['g1'] });
store.set('users/D/private/push', { os: true, mut: ['g1'] }); store.set('users/E/private/push', { os: true }); store.set('blocks/E_A', { by: 'E', to: 'A' });
x = await chat('A', 'g1');
const nb = osCalls.find(c => c.body.headings.en === 'Friends'), lk = osCalls.find(c => c.body.headings.en === 'Snapme');
check('group: two calls (normal and locked), F (no OneSignal phone) is reported as missing', osCalls.length === 2 && x.j.sent === 2 && JSON.stringify(x.j.miss) === '["F"]', [osCalls.length, x]);
check('group: normal one goes to B only (D muted, E blocked the sender) with "Alice: text"', nb && JSON.stringify(nb.body.include_aliases.external_id) === '["B"]' && nb.body.contents.en === 'Alice: party at 8', nb && nb.body);
check('group: the locked one goes to C with no text', lk && JSON.stringify(lk.body.include_aliases.external_id) === '["C"]' && lk.body.contents.en === 'New message', lk && lk.body);

// ================= big group =================
await R();
const many = ['A']; for (let i = 0; i < 300; i++) { many.push('U' + i); store.set('users/U' + i + '/private/push', { os: true }); }
store.set('chats/big', { type: 'group', name: 'Big', members: many, names: {}, last: 'hi', lastTs: now(), lastFrom: 'A' });
const c0 = calls.length; x = await chat('A', 'big');
check('big group: at most 200 people are notified in one call', osCalls.length === 1 && osCalls[0].body.include_aliases.external_id.length === 200, osCalls[0] && osCalls[0].body.include_aliases.external_id.length);
check('big group: 200 people need only a handful of outgoing calls (free plan limit is 50)', calls.length - c0 <= 9, calls.length - c0);

// ================= friend snaps =================
const snapWorld = () => { store.set('posts/p1', { uid: 'A', nm: 'Alice', ts: now(), to: ['A', 'B', 'C', 'D', 'E'], pub: false });
  store.set('users/B/private/push', { os: true }); store.set('users/C/private/push', { os: true, pn: false }); store.set('users/D/private/push', { os: true }); store.set('blocks/D_A', { by: 'D', to: 'A' }); };
await R(); snapWorld();
x = await post({ t: await idToken('A'), k: 'post', post: 'p1' });
check('snap: B is notified, C switched snap alerts off, D blocked the sender, E has no OneSignal phone (missing)', x.j.sent === 1 && JSON.stringify(x.j.miss) === '["E"]' && osCalls.length === 1 && JSON.stringify(osCalls[0].body.include_aliases.external_id) === '["B"]', [x, osCalls.map(c => c.body.include_aliases)]);
check('snap: title is the author, body says it, a tap opens the Feed (post:<id>)', osCalls[0].body.headings.en === 'Alice' && osCalls[0].body.contents.en === 'posted a snap ⚡' && osCalls[0].body.data.chat === 'post:p1', osCalls[0].body);
x = await post({ t: await idToken('A'), k: 'post', post: 'p1' }); check('snap: the same snap again is ignored', x.j.dup === true && osCalls.length === 1, x);
x = await post({ t: await idToken('B'), k: 'post', post: 'p1' }); check('snap: somebody else cannot trigger it', x.st === 404, x);
store.set('posts/old', { uid: 'A', nm: 'A', ts: new Date(Date.now() - 20 * 60e3), to: ['B'] });
x = await post({ t: await idToken('A'), k: 'post', post: 'old' }); check('snap: an old snap gets no push', x.st === 400, x);

// ================= friend requests =================
await R(); store.set('requests/A_B', { from: 'A', to: 'B', fromName: 'Alice Smith', status: 'pending', ts: now() });
x = await post({ t: await idToken('A'), k: 'req', to: 'B' });
check('request: B is notified "Alice sent you a friend request", a tap opens the notifications (nf:req)', x.j.sent === 1 && osCalls[0].body.contents.en === 'Alice sent you a friend request' && osCalls[0].body.data.chat === 'nf:req' && JSON.stringify(osCalls[0].body.include_aliases.external_id) === '["B"]', [x, osCalls[0] && osCalls[0].body]);
x = await post({ t: await idToken('A'), k: 'req', to: 'B' }); check('request: the same request again is ignored', x.j.dup === true, x);
x = await post({ t: await idToken('C'), k: 'req', to: 'B' }); check('request: somebody who sent no request cannot trigger it', x.st === 404, x);
await R(); store.set('requests/A_B', { from: 'A', to: 'B', status: 'accepted', ts: now() });
x = await post({ t: await idToken('A'), k: 'req', to: 'B' }); check('request: an answered request gives no push', x.st === 404, x);
await R(); store.set('requests/A_B', { from: 'A', to: 'B', status: 'pending', ts: now() }); store.set('blocks/B_A', { by: 'B', to: 'A' });
x = await post({ t: await idToken('A'), k: 'req', to: 'B' }); check('request: a blocked sender gives no push', x.j.sent === 0 && osCalls.length === 0, x);
await R(); store.set('requests/A_B', { from: 'A', to: 'B', status: 'pending', ts: now() }); store.delete('users/B/private/push');
x = await post({ t: await idToken('A'), k: 'req', to: 'B' }); check('request: a receiver without a OneSignal phone gets nothing from here', x.j.sent === 0 && osCalls.length === 0, x);

// ================= likes, comments, accepted requests (the notification documents) =================
await R();
store.set('users/B/notifs/lk_p1_A', { t: 'like', from: 'A', n: 'Alice', r: 'f', p: 'p1', ts: now() });
store.set('users/B/notifs/lk_p2_A', { t: 'like', from: 'A', n: 'Alice', r: 'h', p: 'p2', ts: now() });
store.set('users/B/notifs/cm_c1', { t: 'comment', from: 'A', n: 'Alice', p: 'p1', c: 'c1', x: 'nice\n  shot', ts: now() });
store.set('users/B/notifs/ac_A', { t: 'accept', from: 'A', n: 'Alice', ts: now() });
const nf = async (id, u = 'A', to = 'B') => { osCalls.length = 0; return post({ t: await idToken(u), k: 'nf', to, id }); };
x = await nf('lk_p1_A'); check('like: "Alice liked your snap" to the owner, tap opens notifications', x.j.sent === 1 && osCalls[0].body.contents.en === 'Alice liked your snap' && osCalls[0].body.data.chat === 'nf:lk_p1_A' && osCalls[0].body.headings.en === 'Snapme', osCalls[0] && osCalls[0].body);
x = await nf('lk_p2_A'); check('like: a heart says "loved"', osCalls[0] && osCalls[0].body.contents.en === 'Alice loved your snap', osCalls[0] && osCalls[0].body);
x = await nf('cm_c1'); check('comment: "Alice commented on your snap: nice shot"', osCalls[0] && osCalls[0].body.contents.en === 'Alice commented on your snap: nice shot', osCalls[0] && osCalls[0].body);
x = await nf('ac_A'); check('accept: "Alice accepted your friend request"', osCalls[0] && osCalls[0].body.contents.en === 'Alice accepted your friend request', osCalls[0] && osCalls[0].body);
x = await nf('lk_p1_A'); check('like: the same like again within 10 minutes is ignored (no spam by un-like / like)', x.j.dup === true && osCalls.length === 0, x);
x = await nf('lk_p1_A', 'C'); check('like: somebody else cannot trigger it for a like they did not write', x.st === 404, x);
x = await nf('nope'); check('like: an unknown notification gives 404', x.st === 404, x);
x = await nf('lk_p1_A', 'A', 'A'); check('like: you cannot notify yourself', x.st === 400, x);
store.set('users/B/notifs/zz', { t: 'weird', from: 'A', ts: now() });
x = await nf('zz'); check('nf: an unknown type is refused', x.st === 400, x);
store.set('users/B/notifs/old', { t: 'like', from: 'A', n: 'A', ts: new Date(Date.now() - 30 * 60e3) });
x = await nf('old'); check('nf: an old notification gives no push', x.st === 400, x);
await R(); store.set('users/B/notifs/lk_p1_A', { t: 'like', from: 'A', n: 'Alice', ts: now() }); store.delete('users/B/private/push');
x = await nf('lk_p1_A'); check('like: a receiver without a OneSignal phone gets nothing from here', x.j.sent === 0 && osCalls.length === 0, x);
await R(); store.set('users/B/notifs/lk_p1_A', { t: 'like', from: 'A', n: 'Alice', ts: now() }); store.set('users/B/private/push', { os: false });
x = await nf('lk_p1_A'); check('like: notifications switched off -> nothing', x.j.sent === 0 && osCalls.length === 0, x);

// ================= OneSignal problems =================
await R(); osReply = () => ({ status: 400, body: { errors: ['All included players are not subscribed'] } });
x = await send(); check('onesignal: an error is reported as text, not thrown', x.st === 200 && x.j.ok === false && /not subscribed/.test(x.j.err) && x.j.sent === 0, x);
await R(); osReply = () => ({ status: 200, body: { id: '', errors: { invalid_aliases: { external_id: ['B'] } } } });
x = await send(); check('onesignal: nobody subscribed -> sent 0 and a hint', x.j.sent === 0 && /OneSignal/.test(x.j.err), x);
await R(); fsStatus = 403;
x = await send(); check('firestore: a refusal is explained (service account permissions)', x.st === 502 && /service account/.test(x.j.err), x);

// ================= test push =================
await R();
x = await post({ t: await idToken('A'), test: true });
check('test push: goes to the caller only', x.j.ok === true && x.j.sent === 1 && osCalls.length === 1 && JSON.stringify(osCalls[0].body.include_aliases.external_id) === '["A"]' && !osCalls[0].body.data, x);
await R(); osReply = () => ({ status: 200, body: { id: '' } });
x = await post({ t: await idToken('A'), test: true });
check('test push: when OneSignal has no phone for the caller, the answer says so', x.j.ok === false && x.j.sent === 0 && /no active phone/.test(x.j.err), x);
await R(); osReply = () => ({ status: 403, body: { errors: ['Access denied. Please include an Authorization header'] } });
x = await post({ t: await idToken('A'), test: true });
check('test push: a wrong REST key is explained', x.j.ok === false && /OneSignal: Access denied/.test(x.j.err), x);

// ================= rate limit =================
await R();
let last; for (let i = 0; i < 95; i++) last = await post({ t: await idToken('RL'), test: true });
check('rate limit: after 90 calls a minute the caller gets 429', last.st === 429, last);

// ================= no secret leaks =================
await R(); fsStatus = 500;
x = await send();
check('errors: nothing secret is in an error answer', !JSON.stringify(x).includes('REST-KEY') && !JSON.stringify(x).includes('PRIVATE KEY'), x);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
