# VText 💬

A WhatsApp-style chat app. Frontend: GitHub Pages (`index.html`). Deploy: GitHub Actions. Backend: Firebase (free Spark plan: Authentication + Firestore). Optional Android app built by GitHub Actions (Capacitor).

## One-time setup
1. **Firebase** (console.firebase.google.com)
   - Build > Authentication > Sign-in method: turn **Email/Password** on.
   - Build > Firestore Database > Create database (production mode).
   - Firestore > **Rules**: paste the whole content of `firestore.rules` and press **Publish**. (Do this again whenever `firestore.rules` changes. The friend-request, private-account, unfriend and username rules live there.)
   - Project settings > Your apps > Web: the config is already inside `index.html` for project `vtext-506f7`. If you use another project, replace the `FIREBASE_CONFIG` block in `index.html`.
   - Auto-delete: Firestore > **TTL** > create a policy for collection group `messages` on field `expireAt`, and another for `parts` on `expireAt`. The app hides expired messages immediately; TTL removes them from the database.
2. **GitHub**: put all files in the repo (branch `main`). Repo > Settings > Pages > Source = **GitHub Actions**. The workflow `Deploy VText` publishes `https://USERNAME.github.io/REPO/`.
3. Firebase > Authentication > Settings > **Authorized domains**: add `USERNAME.github.io`.
4. Replace `YOUR_EMAIL@example.com` with your support email in `index.html`, `privacy.html`, `terms.html` and `delete-account.html`.

## How the app works
- Create an account with name, username, email and password. Friends find you by username.
- Public accounts can be added directly. A **private account** must receive a friend request first; messages flow only after it is accepted. After an **unfriend**, the chat is deleted for both people and a new request is needed to chat again.
- Blocked people cannot see your username, email, photo or online status. Unblocking keeps the friendship.
- Optional fingerprint lock (stored only on the phone). After 2 failed fingerprint tries the account password unlocks the app.
- You can change your username once in a while; the old one is retired forever.
- Messages expire automatically (1 hour, 24 hours, 7 days or 30 days). Set the time per chat from the chat's ⋮ menu > **Disappearing messages**; in a one-to-one chat you can also choose **Right after reading** (the message is deleted about 10 seconds after the other person sees it). The default for new chats is in Settings > Chat Settings. There is no backup.
- Photos and videos can be saved to the phone: open one and tap **Save**, or use the chat's ⋮ menu > **Photos & videos · save**. (The Android app saves into the gallery; the website downloads the file.)
- Re-publish `firestore.rules` after this update: it adds the unread counters and the after-reading delete rule.

## Updating the website app
Push to `main`: `Deploy VText` stamps the version (`1.0.<run number>`) into the app. On the phone open **Settings > App update**; the app only updates when you tap it, and the visible version changes.

## Android APK
1. The repo must contain `package.json`, `capacitor.config.json`, `scripts/` (including `vtext-debug.keystore.b64`), `assets/` and `.github/workflows/android.yml`.
2. Actions > **Build APK (test)** > Run workflow. After about 10 minutes `VText.apk` is in the repo's **Releases** (right side) and in the run's Artifacts.
3. The APK loads the website, so changing `index.html` does **not** need a new APK. Build a new APK only when native things change (fingerprint, background service, icons).
4. Every APK has an increasing version code and is signed with the same key, so a new APK installs over the old one. **If you installed an APK built before this key was added, uninstall it once** (the signing key changed), then install the new one.
5. The build tries the full app first; if an optional part (fingerprint plugin or background service) fails, it builds a simpler APK and says so in the release notes.

### Notifications in the background (free plan)
VText keeps a small "running" notification and asks Android to exclude it from battery optimisation, so messages reach you while the app is in the background. Real push notifications for a **force-stopped** app need Firebase Cloud Messaging with a server (Firebase Blaze plan), which is not free, so VText does not use it.

## Play Store
See `PLAY-STORE.md`.
