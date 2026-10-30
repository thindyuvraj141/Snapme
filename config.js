// Optional settings. You can change this small file without touching index.html.
// (The Firebase keys below are also inside index.html; they are only repeated here for reference.)
window.firebaseConfig = {
  apiKey: "AIzaSyAoHNNXxK3a8wGW0ijltSEfihfda6Z260o",
  authDomain: "snapmeapp.firebaseapp.com",
  projectId: "snapmeapp",
  storageBucket: "snapmeapp.firebasestorage.app",
  messagingSenderId: "987424998850",
  appId: "1:987424998850:web:f221357852e9fc2380c25b"
};

// ---- Push notifications (see README > "Push notifications") ----
// Web push key for browsers: Firebase console > Project settings > Cloud Messaging > Web Push certificates > "Generate key pair",
// then paste the long key between the quotes. Leave it empty to keep browser push off. (The Android app does not need it.)
window.VT_VAPID = 'BNaOKkk5Ye0a9A2pz5rYwcYNQY3E5fMu5_yqcjrgNDdrfl5lBolJGYBuHxLZmQ55HQuYavIiQKAccRicT74YCMc';
// Set to true ONLY after you deployed the Cloud Function from the "functions" folder (needs the Firebase Blaze plan).
// Then the server sends the message notifications and the app stops showing its own copy, so you never get two.
window.VT_PUSH_SERVER = false;

// ---- Expo Push (free, https://expo.dev). OFF while this is empty. Android app only. See README > "Expo Push". ----
// 1. Create a free account + project on expo.dev (any name), copy its Project ID (a long id like 1b2c3d4e-....).
// 2. Paste it between the quotes. 3. Upload your Firebase service-account key to that Expo project (Credentials > Android > FCM V1).
// With it on, a phone that gets a new message while Snapme is closed is woken by Expo Push; the app stops showing its own copy.
window.VT_EXPO_PROJECT_ID = '070c589f-6a18-4a53-8fe4-f419b0c88972';
