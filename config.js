// Optional settings. You can change this small file without touching index.html.
// (The Firebase keys below are also inside index.html; they are only repeated here for reference.)
window.FIREBASE_CONFIG = {
  apiKey: "AIzaSyBkh_MJ6qBZySNvUwitl1iuvdGK1iadS6k",
  authDomain: "vtext-506f7.firebaseapp.com",
  projectId: "vtext-506f7",
  storageBucket: "vtext-506f7.firebasestorage.app",
  messagingSenderId: "448390510213",
  appId: "1:448390510213:web:0b96f283bedf72d43ddbec"
};

// ---- Push notifications (see README > "Push notifications") ----
// Web push key for browsers: Firebase console > Project settings > Cloud Messaging > Web Push certificates > "Generate key pair",
// then paste the long key between the quotes. Leave it empty to keep browser push off. (The Android app does not need it.)
window.VT_VAPID = '';
// Set to true ONLY after you deployed the Cloud Function from the "functions" folder (needs the Firebase Blaze plan).
// Then the server sends the message notifications and the app stops showing its own copy, so you never get two.
window.VT_PUSH_SERVER = false;
