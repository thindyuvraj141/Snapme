# VText 💬

A WhatsApp-style chat app. Frontend: GitHub Pages (`index.html`). Deploy: GitHub Actions. Backend: Firebase (free Spark plan: Authentication + Firestore). Optional Android app built by GitHub Actions (Capacitor).

## One-time setup
1. **Firebase** (console.firebase.google.com)
   - Build > Authentication > Sign-in method: turn **Email/Password** on.
   - Build > Firestore Database > Create database (production mode).
   - Firestore > **Rules**: paste the whole content of `firestore.rules` and press **Publish**. (Do this again whenever `firestore.rules` changes. The friend-request, private-account, unfriend, username, **location-sharing** and **admin panel** rules live there.)
   - Project settings > Your apps > Web: the config is already inside `index.html` for project `vtext-506f7`. If you use another project, replace the `FIREBASE_CONFIG` block in `index.html`.
   - Auto-delete: Firestore > **TTL** > create a policy for collection group `messages` on field `expireAt`, and another for `parts` on `expireAt`. The app hides expired messages immediately; TTL removes them from the database.
2. **GitHub**: put all files in the repo (branch `main`). Repo > Settings > Pages > Source = **GitHub Actions**. The workflow `Deploy VText` publishes `https://USERNAME.github.io/REPO/`.
3. Firebase > Authentication > Settings > **Authorized domains**: add `USERNAME.github.io`.
4. The support email `VVaultweb@gmail.com` is already set in `index.html`, `privacy.html`, `terms.html` and `delete-account.html`. Change it in those four files if you want another address.

## How the app works
- Create an account with name, username, email and password. Friends find you by username.
- Public accounts can be added directly. A **private account** must receive a friend request first; messages flow only after it is accepted. After an **unfriend**, the chat is deleted for both people and a new request is needed to chat again.
- Blocked people cannot see your username, email, photo or online status. Unblocking keeps the friendship.
- App lock (Profile > Settings > Safety & Visibility): asks for your account password every time the app is opened. **Fingerprint unlock** is a second switch there: it needs the newest APK and at least one fingerprint saved in the phone's own Settings. After 2 failed fingerprint tries the account password unlocks the app. Everything is stored only on the phone.
- You can change your username once in a while; the old one is retired forever.
- Messages are deleted automatically. Set it per chat from the chat's ⋮ menu > **Auto-delete**: **After seen** (one-to-one chats only: the message is deleted about 10 seconds after the other person sees it), **Today** (24 hours) or **7 days**. The default for new chats is in Settings > Chat Style. There is no backup.
- Photos and videos can be saved to the phone: open one and tap **Save**, or use the chat's ⋮ menu > **Photos & videos · save**. (The Android app saves into the gallery; the website downloads the file.)
- **Re-publish `firestore.rules` after this update.** It adds the `locs` rule used by the Friends map. Until it is published, turning on location sharing shows “Please publish the latest Firestore rules”.
- The round neon button on the Chats tab opens the camera directly. New group is in the ⋮ menu.
- Settings > **Share VText** shares the GitHub Releases page `https://github.com/thindyuvraj141/VText/releases` (where the APK is published) with your username.
- Profile page: the **Background** button puts a gallery photo or a colour style behind your profile photo (saved on your profile, only you see it). **Settings** is the last section of the Profile tab (below Account). Under your photo the Name / Username / Save card edits your name; tap Username to change it.
- **Friends page = Friends + Requests.** The bottom bar is Friends · Chats · + · Location · Profile. “My friends” is on top, then a divider, then “Friend requests” (Accept / Decline) and “Sent requests” (Cancel). The red request counter sits on the Friends button.
- **Location page (Friends map)** — the pin button in the bottom bar. A dark neon map shows your friends who share their location, with their photo, how far away they are and when they were last seen; the people-button opens the “Friends nearby” list (within 5 km first). Sharing is **off by default** and is only started after a consent card. You can share with all friends or selected friends, exact or approximate (about 1 km), and stop any time. People you blocked or unfriended never see you. Your position is saved in the Firestore collection `locs` (one document per person, deleted when you stop sharing, log out or delete the account). Location is updated **only while VText is open** (no background tracking, so no “always allow” permission is needed). Map pictures (tiles) come from OpenStreetMap (free, **no API key needed**, needs internet; the credit is shown on the map). If a tile does not load, OSM France and then Esri are tried automatically. (CARTO was used first but now demands an API key, so it is not used any more.) OpenStreetMap's rules are for light use like a friends app; if VText ever gets very many users, switch to a paid tile service with your own key (change `LOC_TILES` in the code).
- **Permission screen:** after sign-in VText asks once for Camera, Gallery (photos/videos) and Location. It can be opened again from Settings > **App permissions**. The Android permission dialogs need the **new APK** (the website alone only asks for camera and location through the browser).
- Deleting your account goes back to the Welcome page and also removes your shared location.

## Admin panel (a separate website, not part of this app)
The admin panel is **not in this repository and not in the app**. It is one separate file (`panel.html`) on its own website, so nothing about it can be found by opening VText. The app only contains the small part that obeys it: the switches, maintenance screen, announcement, force-update screen (installed Android app only), blocked words, the verified badge, and the suspended-account screen (with an end time and an appeal form) and the one-time warning. These read one public settings document (`config/app`) and the person's own records (`bans/<uid>`, `appeals/<uid>`, `warnings/<uid>`); only an admin can change them, and that is enforced by `firestore.rules`, not by hiding the page.

- Publish the newest `firestore.rules` (Firebase console > Firestore Database > Rules > Publish). It adds `admins`, `bans`, `appeals`, `warnings`, `adminnotes`, `config`, `reports` and `adminlog`, and the owner's right to give the verified badge.
- The panel, its setup steps and its privacy notes are in the file `ADMIN-SITE-README.txt` that comes with the panel download (keep it on your own phone; it is not part of this repository). Do **not** put the address of the panel into this public repository.
- What the panel can do: suspend / unsuspend users (the person sees the reason and cannot send messages, friend requests or create chats), read the in-app reports and remove the reported message or chat, maintenance mode, 8 on/off switches (Location, Camera, Voice messages, Creating groups, Photos/videos/documents, Avatar maker, Adding new friends, New sign-ups), announcements, add / remove moderators, an action log, and a “Claude” tab that runs a list of commands that Claude wrote for you after you check it.
- Honest limits: only **Suspend** (including its end time) is enforced by the server. Maintenance mode, the feature switches, “sign-ups closed”, the blocked words and the minimum app version are enforced by the app, so they stop normal users but not somebody who modifies the app code on purpose. Admins can open only the one message that was reported, never anybody's chats.

## Push notifications (messages when the app is closed)
What is already inside the app (nothing to change in the code):
- **Android app:** the Capacitor plugin `@capacitor/push-notifications` is installed by the APK build, the manifest has the notification permission and the default notification channel/icon, and the app registers the phone with Firebase Cloud Messaging after sign-in. Tapping a push opens that chat.
- **Website / installed web app:** `firebase-messaging-sw.js` (own scope, so `sw.js` is not touched) shows pushes in browsers.
- Each phone/browser saves its token in `users/<uid>/private/push` (only you can read it). Turning notifications off, logging out or deleting the account removes it.
- Settings > Notifications > **Push notifications** tells you the state of this phone (On / Not set up yet / Needs the newest APK / Blocked).

What YOU have to do once (all free except step 4):
1. **Firebase console > Project settings > Your apps > Add app > Android.** Package name: `com.thindyuvraj.vtext`. Skip the other steps, then press **Download google-services.json**.
2. Upload that file to the repo as **`scripts/google-services.json`**. Then run **Actions > Build APK** again and install the new APK. (Without the file the app still works; the Settings row says “Not set up yet”.)
3. *Browsers only (optional):* Firebase console > Project settings > **Cloud Messaging** > Web Push certificates > **Generate key pair**. Copy the key into `config.js` as `window.VT_VAPID = '...'`.
4. **Sending the pushes needs a server.** Firebase's free Spark plan cannot run Cloud Functions, so nothing sends a push yet and the app keeps using its own background notifications. To switch real push on: upgrade the project to the **Blaze** plan (pay-as-you-go; the free quota is far more than this app uses, but a card is needed), then deploy `functions/` (the GitHub action **Deploy push function**: add a secret `FIREBASE_SERVICE_ACCOUNT` containing a Google service-account JSON key, then Actions > Deploy push function > Run). Open `functions/index.js` first and set `REGION` to your Firestore location. Finally set `window.VT_PUSH_SERVER = true;` in `config.js` so the app does not show a second copy of every notification.
- Pushes show the sender's name and the message text (text is cut at 100 characters; photos show “📷 Photo”). Locked chats show only “VText · New message”, muted chats stay silent. Set `SHOW_TEXT = false` in `functions/index.js` to hide the text.
- A phone that was force-stopped by the user gets nothing from any app until it is opened again (Android rule).

## Updating the website app
Push to `main`: `Deploy VText` stamps the version (`1.0.<run number>`) into the app. On the phone open **Settings > App update**; the app only updates when you tap it, and the visible version changes.

## Android APK
1. The repo must contain `package.json`, `capacitor.config.json`, `scripts/` (including `vtext-debug.keystore.b64`), `assets/` and `.github/workflows/android.yml`.
2. Actions > **Build APK (test)** > Run workflow. After about 10 minutes `VText.apk` is in the repo's **Releases** (right side) and in the run's Artifacts.
3. The APK loads the website, so changing `index.html` does **not** need a new APK. Build a new APK only when native things change (fingerprint, background service, permission dialogs, icons).
4. Every APK has an increasing version code and is signed with the same key, so a new APK installs over the old one. **If you installed an APK built before this key was added, uninstall it once** (the signing key changed), then install the new one.
5. The build tries the full app first; if an optional part (fingerprint plugin or background service) fails, it builds a simpler APK and says so in the release notes.

### Notifications in the background (free plan, no server, no Google push)
VText shows a small "running" notification and asks Android to exclude it from battery optimisation. While the app screen exists (even in the background) the normal chat connection delivers the notifications.

**Hidden background page.** When the app screen is gone (you swipe it away, press Back until it closes, or Android closes it to save memory) the background service opens the same VText page in a hidden WebView (the address ends with `?bg=1`). That page keeps listening to your chats and asks the service to show the notification; tapping it opens the app on that chat. The hidden page never marks you online, never shows the lock screen and never asks for permissions. It stops by itself when you log out, and it is also started again after the phone restarts or VText is updated (only if "Keep running in the background" was on). The code is in `scripts/android/VTextHeadless.java.tpl` and `VTextBoot.java.tpl`.

If this part ever fails to compile, the build script builds the APK again without it and says so in the release notes ("Hidden background page ... NOT included"); everything else still works.

Honest limits (this is true for every app that does not use Google's push): **Force stop** (Settings > Apps > VText > Force stop) stops it until you open VText once; some phones (Xiaomi, Oppo, Vivo, Realme, Samsung "sleeping apps") close background apps on their own, so allow VText in the battery / autostart settings of the phone; with the screen off for a long time Android can delay the connection (usually seconds to a few minutes). Real push for a force-stopped app needs Firebase Cloud Messaging with a server, which VText does not use.

## Play Store
See `PLAY-STORE.md`.
