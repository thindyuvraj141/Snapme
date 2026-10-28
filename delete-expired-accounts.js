'use strict';
/*
 * Snapme: deletes the accounts whose 7-day deletion period is over.
 *
 * Runs once a day from .github/workflows/delete-accounts.yml (free GitHub Actions) with a Firebase service account key
 * stored in the GitHub secret FIREBASE_SERVICE_ACCOUNT.
 *
 * An account is due when users/<uid> has `delReq` (server time of the "Delete account" tap) older than 7 days.
 * Logging in again within the 7 days removes `delAt` and `delReq` (the app does that), so those accounts are never touched.
 *
 * Per account (everything is safe to repeat; if a step fails the account stays marked and the next run tries again):
 *   - current username, location, big photo, warnings, appeals, admin notes, ban record, moderator role
 *   - friend requests (sent and received), blocks, unfriend records
 *   - one-to-one chats (with all messages), the person is removed from groups (a group nobody is left in is deleted)
 *   - their snaps in the Feed (posts where uid == the person); their Memories go with users/<uid>/memories
 *   - the Firebase Authentication login
 *   - users/<uid> with its sub-collections (last, so a failed run is found again)
 * Owner accounts (admins/<uid>.role == "owner") are never deleted automatically.
 *
 * Also every run (purgeOldSnaps): snaps are visible for 24 hours; the ones that are more than 24 hours past their end (48 hours old) are deleted,
 * EXCEPT the newest snap of each person (posts.lt == true): it stays in the Feed until that person posts a new one, for 30 days at most,
 * and notifications (users/<uid>/notifs) older than 30 days are deleted (that step needs a one-time Firestore index for the collection group
 * "notifs" on `ts`; without it the step is skipped with a log line and the app still removes a person's old notifications when they open the
 * Notifications page).
 * Memories (users/<uid>/memories) are NEVER deleted by this job: they stay until the person deletes them or the account is deleted.
 *
 * Usage:  node scripts/delete-expired-accounts.js            (needs FIREBASE_SERVICE_ACCOUNT or GOOGLE_APPLICATION_CREDENTIALS)
 *         DRY_RUN=1 node scripts/delete-expired-accounts.js  (only lists what would be deleted)
 */

const DAY = 864e5;

async function docsOf(q) { return (await q.get()).docs; }

async function purgeUser(ctx, uid) {
  const { db, auth, FieldValue, dry } = ctx;
  const gone = [];
  const del = async ref => { gone.push(ref.path); if (!dry) await ref.delete(); };
  const tree = async ref => { gone.push(ref.path + '/**'); if (!dry) await db.recursiveDelete(ref); };

  // username (a retired username stays retired for good)
  for (const d of await docsOf(db.collection('usernames').where('uid', '==', uid))) {
    // the "log in with a username" lookup (logins/<username> = { uid, em }) holds the email: it goes with the account
    const lg = db.doc('logins/' + d.id), ls = await lg.get();
    if (ls.exists && (ls.data() || {}).uid === uid) await del(lg);
    if (!(d.data() || {}).retired) await del(d.ref);
  }
  // single documents
  for (const p of ['locs/' + uid, 'photos/' + uid, 'warnings/' + uid, 'appeals/' + uid, 'adminnotes/' + uid, 'bans/' + uid, 'admins/' + uid]) {
    const r = db.doc(p);
    if ((await r.get()).exists) await del(r);
  }
  // requests, blocks, unfriend records
  for (const [col, f, op] of [['requests', 'from', '=='], ['requests', 'to', '=='], ['blocks', 'by', '=='], ['blocks', 'to', '=='], ['unfriends', 'members', 'array-contains']]) {
    for (const d of await docsOf(db.collection(col).where(f, op, uid))) await del(d.ref);
  }
  // snaps in the Feed (the Memories copy lives under users/<uid> and goes with it)
  for (const d of await docsOf(db.collection('posts').where('uid', '==', uid))) await tree(d.ref);
  // chats
  for (const d of await docsOf(db.collection('chats').where('members', 'array-contains', uid))) {
    const c = d.data() || {};
    const rest = (c.members || []).filter(m => m !== uid);
    if (c.type !== 'group' || !rest.length) { await tree(d.ref); continue; }
    const upd = { members: FieldValue.arrayRemove(uid), admins: FieldValue.arrayRemove(uid) };
    for (const k of ['names', 'photos', 'unames', 'emails', 'un', 'seen', 'typing', 'deliv', 'xpt']) upd[k + '.' + uid] = FieldValue.delete();
    if (!(c.admins || []).some(a => a !== uid)) upd.admins = [rest[0]];   // the group keeps an admin
    gone.push(d.ref.path + ' (removed from group)');
    if (!dry) await d.ref.update(upd);
  }
  // login, then the profile (the marker that makes a failed run find this person again)
  gone.push('auth:' + uid);
  if (!dry) {
    try { await auth.deleteUser(uid); }
    catch (e) { if (!e || e.code !== 'auth/user-not-found') throw e; }
  }
  await tree(db.doc('users/' + uid));
  return gone;
}

/** Deletes every account whose deletion period is over. Returns { due, deleted, skipped, failed }. */
async function purgeExpired(ctx) {
  const { db, Timestamp, now = Date.now(), days = 7, log = console.log } = ctx;
  const cutoff = Timestamp.fromMillis(now - days * DAY);
  const due = await docsOf(db.collection('users').where('delReq', '<=', cutoff));
  const out = { due: due.length, deleted: 0, skipped: 0, failed: 0 };
  log('accounts due for deletion: ' + due.length + (ctx.dry ? ' (dry run: nothing is changed)' : ''));
  for (const d of due) {
    const uid = d.id, u = d.data() || {};
    try {
      if (!u.delAt) { log('skip ' + uid + ': not marked for deletion any more'); out.skipped++; continue; }
      const a = await db.doc('admins/' + uid).get();
      if (a.exists && (a.data() || {}).role === 'owner') { log('skip ' + uid + ': owner accounts are never deleted automatically'); out.skipped++; continue; }
      const gone = await purgeUser(ctx, uid);
      log((ctx.dry ? 'would delete ' : 'deleted ') + uid + ' (' + gone.length + ' items)');
      out.deleted++;
    } catch (e) {
      out.failed++;
      log('FAILED ' + uid + ': ' + (e && e.message ? e.message : e));
    }
  }
  log('done: ' + JSON.stringify(out));
  return out;
}

/** Deletes snaps that ended more than 24 hours ago (except the NEWEST snap of a person: it stays until he posts a new one, for 30 days at most)
 *  and notifications older than 30 days. Memories are kept (only the person can delete them). Returns { posts, kept, notifs, notifsSkipped }. */
async function purgeOldSnaps(ctx) {
  const { db, Timestamp, now = Date.now(), log = console.log, dry } = ctx;
  const out = { posts: 0, kept: 0, notifs: 0, notifsSkipped: false };
  const rm = async (d, key) => {
    // a snap with a video also has its pieces under posts/<id>/parts
    if (!dry) { if (key === 'posts' && typeof db.recursiveDelete === 'function') await db.recursiveDelete(d.ref); else await d.ref.delete(); }
    out[key]++;
  };
  // snaps: walk through them in pages (the kept ones stay, so a page cannot simply be re-read)
  let last = null;
  for (let round = 0; round < 50; round++) {          // at most 50 x 400 per run; the next run continues
    let q = db.collection('posts').where('exp', '<', now - DAY).orderBy('exp').limit(400);
    if (last) q = q.startAfter(last);
    const docs = await docsOf(q);
    for (const d of docs) {
      const x = d.data() || {};
      if (x.lt === true && (x.exp || 0) > now - 29 * DAY) { out.kept++; continue; }
      await rm(d, 'posts');
    }
    if (docs.length < 400) break;
    last = docs[docs.length - 1];
  }
  // optional sweep over a collection group (needs a one-time Firestore index on `ts`; without it the step is skipped with a log line)
  const sweep = async (name, key, skipKey, cutoff) => {
    try {
      if (typeof db.collectionGroup !== 'function') throw new Error('no collection group');
      for (let round = 0; round < 50; round++) {
        const docs = await docsOf(db.collectionGroup(name).where('ts', '<', cutoff).limit(400));
        for (const d of docs) await rm(d, key);
        if (dry || docs.length < 400) break;
      }
    } catch (e) {
      out[skipKey] = true;
      log(name + ' clean-up skipped (optional): ' + (e && e.message ? String(e.message).split('\n')[0].slice(0, 200) : e));
    }
  };
  // notifications: ts is a server timestamp, so the cut-off must be a Timestamp / Date
  await sweep('notifs', 'notifs', 'notifsSkipped', Timestamp && Timestamp.fromMillis ? Timestamp.fromMillis(now - 30 * DAY) : new Date(now - 30 * DAY));
  log((dry ? 'would delete ' : 'deleted ') + out.posts + ' old snaps (' + out.kept + ' newest snaps kept) and ' + out.notifs + ' old notifications');
  return out;
}

module.exports = { purgeExpired, purgeUser, purgeOldSnaps };

if (require.main === module) {
  (async () => {
    const admin = require('firebase-admin');
    const raw = process.env.FIREBASE_SERVICE_ACCOUNT;
    admin.initializeApp(raw ? { credential: admin.credential.cert(JSON.parse(raw)) } : {});
    const ctx = {
      db: admin.firestore(), auth: admin.auth(), FieldValue: admin.firestore.FieldValue, Timestamp: admin.firestore.Timestamp,
      dry: process.env.DRY_RUN === '1'
    };
    const out = await purgeExpired(ctx);
    try { await purgeOldSnaps(ctx); } catch (e) { console.log('snap clean-up failed (will retry tomorrow): ' + (e && e.message ? e.message : e)); }
    process.exit(out.failed ? 1 : 0);
  })().catch(e => { console.error(e); process.exit(1); });
}
