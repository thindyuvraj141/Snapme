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
window.VT_VAPID = 'BPsplVeuoerHSxvJa5R8cDBaHNn_6J0I7AsyEMVRqwFl9bjkhHzRdTNO4bbx4T_Sv6sJthXTL_9MiJX3ZFteq28';
// Set to true ONLY after you deployed the Cloud Function from the "functions" folder (needs the Firebase Blaze plan).
// Then the server sends the message notifications and the app stops showing its own copy, so you never get two.
window.VT_PUSH_SERVER = false;

// ---- Expo Push (free, https://expo.dev). OFF while this is empty. Android app only. See README > "Expo Push". ----
// 1. Create a free account + project on expo.dev (any name), copy its Project ID (a long id like 1b2c3d4e-....).
// 2. Paste it between the quotes. 3. Upload your Firebase service-account key to that Expo project (Credentials > Android > FCM V1).
// With it on, a phone that gets a new message while VText is closed is woken by Expo Push; the app stops showing its own copy.
window.VT_EXPO_PROJECT_ID = '09381185-bafd-479f-acc9-854f300d606f';
