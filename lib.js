'use strict';
// Pure helpers for the VText push function (no Firebase libraries here, so they can be tested with plain Node).

const STALE = ['messaging/registration-token-not-registered', 'messaging/invalid-registration-token'];
const isStale = code => STALE.includes(code);

/** One line describing a message. Text is cut to 100 characters; media shows a label. */
function preview(m, showText) {
  switch (m && m.type) {
    case 'img': return '📷 Photo';
    case 'vid': return '🎥 Video';
    case 'aud': return '🎤 Voice message';
    case 'loc': return '📍 Location';
    case 'doc': return '📄 ' + String(m.fname || 'Document').slice(0, 30);
    default: {
      if (!showText) return 'New message';
      const t = String((m && m.text) || '').replace(/\s+/g, ' ').trim();
      if (!t) return 'New message';
      return t.length > 100 ? t.slice(0, 99) + '…' : t;
    }
  }
}

/** Notification title and body. Locked chats show no names and no text (same as the app's own notification). */
function titleBody(chat, m, locked, showText) {
  if (locked) return { title: 'VText', body: 'New message' };
  const from = (chat.names && chat.names[m.from]) || m.fromName || 'VText';
  const p = preview(m, showText);
  if (chat.type === 'group') return { title: chat.name || 'Group', body: from + ': ' + p };
  return { title: from, body: p };
}

/**
 * All push messages for ONE recipient.
 * push = users/{uid}/private/push  ->  { t: { deviceId: { k: token, p: 'android'|'web' } }, mut: [chatIds], lck: [chatIds] }
 * Returns [{ devId, message }]. Empty when the chat is muted or the person has no registered phone/browser.
 */
function build(chatId, chat, m, push, opts) {
  const out = [];
  if (!push || !push.t) return out;
  if ((push.mut || []).includes(chatId)) return out;
  const locked = (push.lck || []).includes(chatId);
  const { title, body } = titleBody(chat, m, locked, !(opts && opts.showText === false));
  Object.entries(push.t).forEach(([devId, e]) => {
    if (!e || !e.k) return;
    let message;
    if (e.p === 'web') {
      // browsers get data-only messages: firebase-messaging-sw.js builds the notification and opens the chat on tap
      message = { token: e.k, data: { title, body, chat: chatId }, webpush: { headers: { Urgency: 'high', TTL: '3600' } } };
    } else {
      // the Android app: shown by the phone itself, even when VText is closed
      message = {
        token: e.k,
        notification: { title, body },
        data: { chat: chatId },
        android: { priority: 'high', ttl: 3600 * 1000, notification: { channelId: 'messages', icon: 'ic_stat_vtext', tag: chatId } }
      };
    }
    out.push({ devId, message });
  });
  return out;
}

module.exports = { preview, titleBody, build, isStale };
