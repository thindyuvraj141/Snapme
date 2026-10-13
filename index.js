'use strict';
/**
 * VText push notifications: sends a Firebase Cloud Messaging push to the other people of a chat whenever a message is created.
 * Needs the Firebase Blaze plan (Cloud Functions are not available on the free Spark plan). See README > "Push notifications".
 */
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');
const { build, isStale } = require('./lib');

admin.initializeApp();

// Must be the same region as your Firestore database (Firebase console > Firestore Database > Data shows its location).
// nam5 / United States -> 'us-central1'.  Mumbai -> 'asia-south1'.  Europe (eur3) -> 'europe-west1'.
const REGION = 'us-central1';
// true: the notification shows the message text (like the app does). false: only "New message".
const SHOW_TEXT = true;

exports.pushOnMessage = onDocumentCreated({ document: 'chats/{chatId}/messages/{msgId}', region: REGION }, async event => {
  const snap = event.data;
  if (!snap) return;
  const m = snap.data() || {};
  const chatId = event.params.chatId;
  if (!m.from) return;
  const db = admin.firestore();
  const chatSnap = await db.doc('chats/' + chatId).get();
  if (!chatSnap.exists) return;
  const chat = chatSnap.data() || {};

  const jobs = [];
  await Promise.all((chat.members || []).filter(u => u !== m.from).map(async uid => {
    const [pushSnap, blocked] = await Promise.all([
      db.doc('users/' + uid + '/private/push').get(),
      db.doc('blocks/' + uid + '_' + m.from).get()          // the receiver blocked the sender: stay silent
    ]);
    if (!pushSnap.exists || blocked.exists) return;
    build(chatId, chat, m, pushSnap.data(), { showText: SHOW_TEXT }).forEach(j => jobs.push({ uid, devId: j.devId, message: j.message }));
  }));
  if (!jobs.length) return;

  const res = await admin.messaging().sendEach(jobs.map(j => j.message));

  // tokens Google says are dead (app uninstalled, data cleared) are removed so they are not tried again
  const dead = {};
  res.responses.forEach((r, i) => {
    if (!r.success && isStale(r.error && r.error.code)) (dead[jobs[i].uid] = dead[jobs[i].uid] || []).push(jobs[i].devId);
  });
  await Promise.all(Object.entries(dead).map(([uid, ids]) => {
    const upd = {};
    ids.forEach(id => { upd['t.' + id] = admin.firestore.FieldValue.delete(); });
    return db.doc('users/' + uid + '/private/push').update(upd).catch(() => {});
  }));
});
