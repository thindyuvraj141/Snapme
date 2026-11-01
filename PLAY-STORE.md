# Snapme: Play Store checklist

## One-time steps
1. Create a developer account at play.google.com/console (one-time US$25, ID verification).
2. **Personal accounts created after 13 Nov 2023**: before production you need a closed test with 12 testers opted in for 14 days in a row. Organization accounts do not need this.
3. Create an upload keystore (on a PC or in Termux):
   `keytool -genkeypair -v -keystore vtext.jks -alias vtext -keyalg RSA -keysize 2048 -validity 10000`
   `base64 -w0 vtext.jks` (copy the output). Keep the keystore and passwords safe and never put them in the repo.
4. GitHub repo > Settings > Secrets and variables > Actions: add 4 secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
5. The support email `VVaultweb@gmail.com` is already set in `privacy.html`, `terms.html`, `delete-account.html` and `index.html` (change it there if needed).
6. Firebase: publish the latest `firestore.rules`. In Google Cloud / Firebase, add TTL policies on `messages` and `parts` (field `expireAt`), because the privacy policy says expired messages are removed.

## Every release
Actions > **Build Play Store AAB** > Run workflow > download `Snapme.aab` from Artifacts > upload it in Play Console. The version code increases automatically with every run.
The Play Store build bundles the web files inside the app (so updates go through the store) and, like every build since 30 Oct, has no background service, no boot receiver and no battery-optimisation permission (Google restricts those); messages arrive through the push service. The Play bundle is built without the OneSignal plugin (Round 17); the OneSignal + Worker route is for the test APK that you install yourself.

## Play Console forms
- Package name: `com.thindyuvraj.vtext` (cannot be changed after the first upload).
- Privacy policy URL: https://thindyuvraj141.github.io/VText/privacy.html
- Account deletion URL: https://thindyuvraj141.github.io/VText/delete-account.html
- Category: Communication. Ads: No. Content rating questionnaire: user-generated content / users interact = Yes.
- Data safety: collected = email, name, user IDs, photos/videos (snaps), audio (voice vibes, voice messages), messages, approximate/precise location (only if the user turns on sharing on the Location page; visible only to the friends they choose; foreground only, no background location); encrypted in transit = Yes; users can request deletion = Yes; shared with third parties = No (Firebase is a service provider).
- App access: give the reviewer a test email and password.
- Graphics: `store/icon-512.png`, `store/feature-graphic-1024x500.png`, and at least 2 real phone screenshots.

Short description: Share raw snaps with friends, see a daily Feed, keep Memories and chat.
Full description: Snapme lets you share a raw moment with your friends: take a snap with the dual camera, add filters, a caption and a 10-second voice vibe, and post it to your friends or your Inner Circle (Public accounts also appear in the Public feed). Snaps stay in the Feed for 30 days and your Memories (shown on your Profile like a photo grid) keep the ones you posted until you delete them. Add friends by username, chat one-to-one or in groups, send photos, videos, voice messages and documents, and see on a friends map where your friends are when you both choose to share (sharing is off until you turn it on). Take photos with fun lenses, add stickers and text. Messages disappear automatically after the time you choose.
- Permissions declared: camera, microphone, photos/videos (READ_MEDIA_IMAGES / READ_MEDIA_VIDEO, READ_EXTERNAL_STORAGE up to Android 12), approximate + precise location (foreground only, **no** ACCESS_BACKGROUND_LOCATION), notifications (Firebase Cloud Messaging push, POST_NOTIFICATIONS), biometric (declared by the APK; the fingerprint lock feature itself was removed on 25 Oct). In the Play Console location declaration say: used for the optional friends map, only while the app is open.
- Data safety (28 Oct): the email address is also kept next to the username so that people can log in with their username (switch in Settings); say it is collected for account management / app functionality and not shared.
- Data safety (27 Oct): also declare **Other user-generated content** (comments, bio) and in-app notifications (likes, comments, accepted requests) as app functionality, not shared. Users can see only what the account’s Public/Private setting and friendship allow; the owner of a snap can delete any comment on it, and a user can delete his own comments, Memories and account.
- Data safety: also declare Device or other IDs (Firebase Cloud Messaging token), collected for app functionality (notifications), not shared.
- Privacy policy: the in-app and web privacy text should mention the push token. (Already added to `privacy.html` and the in-app policy.)
