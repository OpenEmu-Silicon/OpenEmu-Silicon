# Privacy Policy

**App:** OpenEmu-Silicon
**Last updated:** October 14, 2026
**Contact:** [Open an issue](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues)

---

## What this app does

OpenEmu-Silicon is a macOS game emulator. Most gameplay and library features run locally on your computer.

The app only connects to external services for features you use, or for optional crash reporting if you consent:

- **RetroAchievements** — optional achievements, leaderboards, and Rich Presence.
- **Google Drive Save Sync** — optional save-state and battery-save backup/sync.
- **Sentry crash reporting** — optional crash and hang diagnostics.
- **CheatWorks** (community cheat ratings): used when you open Browse Online Cheats or rate a cheat. Unlike the features above, it is on by default in official releases. You can turn it off in **Preferences → Gameplay**. See [CheatWorks community cheat ratings](#cheatworks-community-cheat-ratings).

OpenEmu-Silicon does not operate its own account server, telemetry backend, or analytics service.

---

## RetroAchievements (optional)

RetroAchievements support lets you earn achievements, submit leaderboard scores, and show Rich Presence for supported games. It is off unless you sign in from **Preferences → Achievements**.

### What is sent to RetroAchievements

When RetroAchievements is enabled, OpenEmu-Silicon uses the rcheevos client library to communicate with RetroAchievements. Depending on the game and session, this may send:

- Your RetroAchievements login/token request.
- Game hashes and game-identification requests.
- Achievement unlock submissions.
- Leaderboard start/update/submit data.
- Rich Presence updates.
- Client and system information such as the OpenEmu-Silicon User-Agent, macOS version, and rcheevos version.

### What is stored locally

After sign-in, the RetroAchievements token is stored locally in OpenEmu-Silicon's encrypted credential file at `~/Library/Application Support/OpenEmu/.oe_credentials`. The app may also store local preferences such as whether hardcore mode is enabled.

Your RetroAchievements password is not stored by OpenEmu-Silicon.

### Data controlled by RetroAchievements

RetroAchievements is an external service. OpenEmu-Silicon does not operate RetroAchievements servers and does not control RetroAchievements-side retention, account deletion, or profile data. For RetroAchievements account/privacy questions, refer to RetroAchievements directly.

---

## Google Drive Save Sync (optional)

This feature lets you back up and sync your save states and battery saves to your own Google Drive. It is off by default and only activates after you sign in.

### What access is requested

OpenEmu-Silicon requests the `drive.appdata` scope. This gives the app access to a private, hidden App Data folder inside your Google Drive. This folder:

- Is not visible in the Google Drive web interface
- Cannot be read by other apps
- Can only be accessed by OpenEmu-Silicon

The app does **not** request access to your files, documents, photos, or any other part of your Google Drive.

### What is stored in your Drive

Only your game save data:

- Save state files (snapshots of game progress)
- Battery save files (in-game save data)

No personal information, no device identifiers, no usage metrics.

### How authentication works

Sign-in uses Google's standard OAuth 2.0 flow. Your Google account password is never seen or stored by the app. After you authorize access, Google issues an OAuth token. That token is stored locally in OpenEmu-Silicon's encrypted credential file at `~/Library/Application Support/OpenEmu/.oe_credentials` and is used only to read and write your save data to the App Data folder.

### Revoking access

You can disconnect Google Drive at any time from **Preferences → Cloud Sync → Sign Out**. This clears the stored Google Drive token from OpenEmu-Silicon's local credential store. You can also revoke access from your Google Account at [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

---

## Sentry crash reporting (optional)

OpenEmu-Silicon can send crash, hang, and performance diagnostic reports to Sentry. This is optional and consent-gated. On first launch, the app asks whether you want to send crash reports.

If you opt in, reports may include:

- App version and build number.
- macOS/device diagnostic information.
- Stack traces, crash details, hangs, and performance traces.
- Breadcrumbs and structured logs related to app behavior.
- Active game title, system identifier, and core identifier at the time of a crash.

Crash reports do **not** intentionally include:

- Game ROM files.
- Save state files.
- Battery save files.
- Passwords.

Sentry events are sent to Sentry's hosted service. The current project configuration uses Sentry's US ingest endpoint (`ingest.us.sentry.io`). OpenEmu-Silicon does not operate Sentry's servers.

You can decline crash reporting when prompted. If you previously opted in and want to stop future reports, open an issue for help resetting the local crash-reporting preference while a user-facing toggle is being added.

---

## CheatWorks community cheat ratings

CheatWorks is a community service that collects "works" or "doesn't work" reports for cheat codes, so other players can see how well a code has worked. OpenEmu-Silicon uses it to show a rating next to each cheat in **Browse Online Cheats**, and to share your own ratings.

CheatWorks was created by a contributor to OpenEmu-Silicon. It is a separate service. OpenEmu-Silicon does not operate CheatWorks servers.

### When the app contacts CheatWorks

- When you open **Browse Online Cheats**, to look up ratings for the cheats listed.
- When you rate a cheat as "Works", "Doesn't work", or "Not sure".
- At launch, to upload ratings you gave earlier that were not yet uploaded. If you have never rated a cheat, nothing is uploaded.

The app does not contact CheatWorks just because you play a game.

This feature is built into official releases and is on by default. To turn it off, open **Preferences → Gameplay** and clear **Community cheat ratings (CheatWorks)** under Cheats. When it is off, the app does not contact CheatWorks at all, you do not see ratings in Browse Online Cheats, and your ratings stay on your Mac. If you turn it back on, any ratings that have not been uploaded yet, including ones you gave while it was off, are uploaded. Builds made from source without a CheatWorks access token do not upload ratings or register an installation ID, but they still look up ratings when you open Browse Online Cheats.

### What is sent to CheatWorks

When you open Browse Online Cheats (rating lookup):

- A fingerprint of the game file (an MD5 hash). Not the game file itself.
- The identifier of the emulator core you are using (for example `genesisplus`).
- The cheat codes shown in the list, up to 100 at a time.

No installation ID is sent for this lookup.

When you rate a cheat, or when an earlier rating is uploaded:

- The game fingerprint (MD5 hash) and, if known, the game's name.
- The cheat code you rated, your rating, and the cheat provider's name if the code came from one.
- The emulator core identifier and version, and the OpenEmu-Silicon version.
- An installation ID (see below).

As with any internet request, CheatWorks' servers can also see your IP address.

### The installation ID

The first time a rating is uploaded, the app registers an installation ID with CheatWorks. The ID is a one-way hash (SHA-256) of your Mac's hardware identifier combined with a fixed label. Your raw hardware identifier is never sent.

The ID stays the same on this Mac, including after you reinstall OpenEmu-Silicon, and you cannot reset it. CheatWorks uses it to stop one installation from submitting repeated ratings for the same cheat. It is not your name or an account, but it does identify this Mac to CheatWorks over time.

### What is stored locally

- The access token CheatWorks issues to your installation, in an encrypted file at `~/Library/Application Support/<app bundle ID>/CheatWorks/.cheatworks_store`. The encryption key is derived from your Mac's hardware identifier, so this protects the file from casual reading but not from software running on your Mac.
- Your cheat ratings, kept in OpenEmu-Silicon's local cheat feedback files, so they can be uploaded later and shown in the app.

### Data controlled by CheatWorks

OpenEmu-Silicon does not control what CheatWorks does with the data it receives, how long it keeps it, or whether it can be deleted. For questions about that, refer to CheatWorks directly at [cheatworks.org](https://cheatworks.org).

---

## What this app does not do

- Does not sell your data.
- Does not include ads.
- Does not include in-app purchases or subscriptions.
- Does not operate its own analytics backend.
- Does not transmit game ROMs to this project.
- Does not transmit save data to this project.
- Does not access your Google Drive files outside the hidden App Data folder.

---

## Open source

The full source code is available at [github.com/OpenEmu-Silicon/OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon). You can inspect exactly what data is read, written, and transmitted.

---

## Changes to this policy

If the app adds new network features that affect privacy, this document will be updated and the "Last updated" date above will change. Significant changes will be noted in the release notes.

---

## Contact

Questions or concerns? [Open an issue](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues) on GitHub.
