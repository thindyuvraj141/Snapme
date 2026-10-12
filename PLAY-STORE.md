# VText: Play Store checklist

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
Actions > **Build Play Store AAB** > Run workflow > download `VText.aab` from Artifacts > upload it in Play Console. The version code increases automatically with every run.
The Play Store build bundles the web files inside the app (so updates go through the store) and leaves out the background service helper, because Google restricts always-running services and battery-optimisation exemptions.

## Play Console forms
- Package name: `com.thindyuvraj.vtext` (cannot be changed after the first upload).
- Privacy policy URL: https://thindyuvraj141.github.io/VText/privacy.html
- Account deletion URL: https://thindyuvraj141.github.io/VText/delete-account.html
- Category: Communication. Ads: No. Content rating questionnaire: user-generated content / users interact = Yes.
- Data safety: collected = email, name, user IDs, photos/videos, audio, messages, approximate/precise location (only if the user shares it); encrypted in transit = Yes; users can request deletion = Yes; shared with third parties = No (Firebase is a service provider).
- App access: give the reviewer a test email and password.
- Graphics: `store/icon-512.png`, `store/feature-graphic-1024x500.png`, and at least 2 real phone screenshots.

Short description: Simple private chat with photos, voice notes and groups.
Full description: VText is a simple chat app. Add friends by username, chat one-to-one or in groups, send photos, videos, voice messages, documents and your location. Take photos with fun lenses, add stickers and text. Messages disappear automatically after the time you choose.
