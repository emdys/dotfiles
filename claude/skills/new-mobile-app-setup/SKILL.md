---
name: new-mobile-app-setup
description: Use at the very start of a new Expo/React Native mobile app project — or when setting up its shipping pipeline for the first time — to configure GitHub push access, iOS via Xcode Cloud + App Store Connect, and Android via EAS Build + Google Play Console. Covers the concrete gotchas hit while shipping TaskMeal on both platforms.
---

# New mobile app setup (Expo → App Store Connect + Google Play)

This process was learned end-to-end while building and shipping TaskMeal (an Expo/React Native app) on both iOS and Android, across a GitHub Codespaces sandbox that could only push to one repo by default. Follow it in order for any new app of this shape. Don't skip Step 0 — every later failure in this list traces back to a question that wasn't asked up front.

**The two platforms use genuinely separate pipelines, not a shared one**: iOS goes through Xcode Cloud (Apple-only CI, needs a committed native `ios/` project); Android goes through EAS Build (Expo's own cloud CI, generates its native `android/` project fresh each time, nothing committed). Don't assume anything about one platform's setup carries over to the other beyond the shared Expo/React Native app code itself.

## Step 0 — Ask before writing any code

Prompt the user for each of these explicitly. Do not assume defaults, and do not wait for a push/API failure to discover the answer.

1. **GitHub push access.** Sandboxed dev environments (Codespaces, etc.) often only have push access to whatever repo they were created from — not arbitrary new repos. Ask: *"Do you already have a fine-grained GitHub PAT for this repo saved as a Codespaces secret? If not, let's set one up now."*
   - Setup: user creates a fine-grained PAT (github.com/settings/tokens?type=beta) scoped to just the new repo, with **Contents: Read & write**. They add it as a Codespaces secret (repository- or account-level) — this is the permanent fix, not a scratchpad file re-created every session.
   - Once available as an env var (e.g. `$MYAPP_TOKEN`), verify with `git push "https://x-access-token:${MYAPP_TOKEN}@github.com/<owner>/<repo>.git"`.
   - Always redact the token from any command output shown to the user (`sed "s/${TOKEN}/[REDACTED]/g"`). Never print it in full, never commit it.

2. **App Store Connect API access.** Ask: *"Do you have an existing App Store Connect API key (.p8) from a prior app? Team-scoped keys work across every app under the same Apple Developer team, so it can usually be reused."* If not, the user creates one: App Store Connect → Users and Access → Integrations → App Store Connect API → Generate Key (needs Admin access). Save the `.p8` file plus Key ID and Issuer ID **outside any git repo** (or in a gitignored path), e.g. `secrets/appstoreconnect/.env` + the key file.
   - Reuse a generic JWT-based `asc_fetch.py` helper (get/post/patch against `api.appstoreconnect.apple.com/v1`, PyJWT-signed token capped at 20 minutes) — this doesn't need to be rewritten per app, only pointed at new credentials/app IDs.

3. **Apple Developer / bundle ID.** Confirm the bundle identifier and that an App Store Connect app record already exists (or needs creating in App Store Connect first) before attempting a first build.

4. **Data architecture.** Confirm local-only vs. backend-needed explicitly. Don't default to adding a backend, auth, or a serverless proxy without the user asking for one — it's easy to over-build here.

5. **If shipping to Android too: Google Play Console access.** Ask: *"Do you already have a Play Console developer account, and payment/merchant details set up if this is a paid app?"* — the app-side work (native Android project, EAS Build) can start immediately regardless of the answer; the Play Console listing and API access setup (see the Android section below) is independent and can happen in parallel, not a blocker to getting a build working.

## Step 1 — Scaffold + native folder

- `npx create-expo-app`, then run `npx expo prebuild --platform ios` **once** to generate the native `ios/` folder. Commit it to git — do not gitignore it. Xcode Cloud needs the native project checked in (unlike EAS Build, which doesn't).
- ⚠️ **Never re-run `npx expo prebuild --platform ios --clean` later** without a way to test-build the result locally first. It regenerates `ios/` from scratch and silently destroys custom additions: deletes `ios/ci_scripts/`, strips CocoaPods integration out of `project.pbxproj`, and wipes `Podfile.lock` / `.xcworkspace` contents / `PrivacyInfo.xcprivacy`. If this happens, recover with `git checkout HEAD -- <affected files>` and re-verify the recovered files are unchanged before re-committing any intentional change that was bundled in.

## Step 2 — Use Xcode Cloud, not EAS Build

Why: `eas build` (cloud) hit Expo's free-tier monthly quota; `eas build --local` hit an unresolved macOS Keychain/certificate-import failure. Xcode Cloud (Apple's own CI, configured from Xcode against the App Store Connect app record) avoided both and is the default going forward.

- In Xcode: **Product → Xcode Cloud → Create Workflow**, connect the GitHub repo, auto-trigger on push to main.
- Add `ios/ci_scripts/ci_post_clone.sh` (installs Node via Homebrew, then `npm ci`, then `pod install`) and commit it — Xcode Cloud's macOS image has no Node by default.
- ⚠️ **Set the workflow's Archive action distribution to include "App Store" from the very first workflow you create — not just "TestFlight (Internal Testing Only)".** A build archived as internal-only can *never* be attached to an App Store version later; both the App Store Connect UI and API reject it outright (`ENTITY_ERROR.RELATIONSHIP.INVALID` / "the specified pre-release build could not be added"), and there is no fix except producing a brand-new build under a workflow with the distribution setting corrected. On TaskMeal this wasted 17 builds before being caught — check this before the first build, not after.

## Step 3 — Monitor builds via the API, not by asking the user to check Xcode's UI

- Reuse the generic `asc_fetch.py` helper.
- `/ciProducts/{id}/buildRuns`, then `/ciBuildActions` and `/issues` on a failed run's action id, surface the actual build-log error without needing the user to relay screenshots from Xcode.
- `/apps/{id}/builds` shows TestFlight processing state (`processingState`: `VALID` / `PROCESSING` / `FAILED` / `INVALID`).
- Prefer a background Bash task with a sleep-poll loop that exits once on a terminal state over a `Monitor` that echoes every poll — a "tell me when it's done" need is one notification, not one per 30-second check.

## Step 4 — Configuring the App Store Connect submission (once a build exists)

Non-obvious things learned the hard way:

- The App Store version's `versionString` (e.g. `"1.0.0"`) must **exactly** match the build's marketing version (from `app.json`'s `version`, i.e. `CFBundleShortVersionString`) or attaching the build fails with the same cryptic `ENTITY_ERROR.RELATIONSHIP.INVALID` error as the internal-only-build problem in Step 2. Check both causes when this error shows up.
- `ageRatingDeclarations` fields are an inconsistent mix of booleans and severity enums (`"NONE"` / `"INFREQUENT_OR_MILD"` / `"FREQUENT_OR_INTENSE"`), and this isn't reliably documented anywhere — send a first attempt, then fix field-by-field off the API's own "expected a STRING but got BOOLEAN" / "expected one of: ..." error messages rather than guessing blind.
- `ageAssurance` is a required boolean on the age rating declaration (whether the app performs age verification) — easy to miss since it's a newer field.
- `usesIdfa` (advertising identifier usage) on the app store version must be explicitly set `true`/`false`, not left `null`.
- **App Privacy** ("does this app collect data") has no reliable API path found so far — set it directly in the App Store Connect UI (App Privacy → Get Started → answer → Publish). This is privacy/legally-sensitive, so a human doing the UI toggle is preferable to guessing via the API anyway.
- A **support URL** is required and must be a live, resolving page. If the user has no existing site, a published-and-shared Claude Artifact works as a stopgap — remember artifacts are **private by default**, so the user must use the page's own Share control to make it public before Apple's reviewers can load it.
- `appStoreReviewDetails` needs a first/last name and phone number for the reviewer contact — ask the user directly, never guess. If the app has no login system, set `demoAccountRequired: false` and use `notes` to briefly explain how a reviewer can exercise the app's core flow without an account.

## Step 5 — Before actually submitting

Always show the user a final summary of everything configured (build attached, listing copy, age rating, privacy, IDFA, review contact) and get explicit confirmation before creating the `appStoreVersionSubmission`. This starts Apple's review clock and is visible/semi-public — never do it unprompted, even if every prerequisite looks satisfied.

---

# Android (Google Play, via EAS Build)

Everything below is independent of the iOS steps above — different CI, different console, different credential type. Good news: several iOS pain points (Keychain/certificate hell, strict version-string matching, build-distribution-audience traps) simply don't exist on Android.

## Android Step 1 — Scaffold + native folder (opposite convention from iOS)

- `npx expo prebuild --platform android` generates the native `android/` folder — but **do not commit it** (should already be covered by a `/android` line in `.gitignore`; add one if not). Unlike Xcode Cloud, EAS Build doesn't need a committed native project — it runs its own prebuild in the cloud from `app.json` every time. No custom CI script needed either (no Android equivalent of `ios/ci_scripts/ci_post_clone.sh`).
- **Package name is permanent** once the Play Console app listing is created — confirm it's exactly right first (convention: same string as the iOS bundle ID, e.g. `com.company.appname`).

## Android Step 2 — Use EAS Build (this is a completely different situation from the iOS EAS quota problem)

If a prior app on this same Expo account hit `eas build` quota/Keychain issues on iOS and abandoned EAS Build entirely for iOS — **that does not carry over to Android.** iOS and Android build credits are tracked as **separate pools** on EAS's free tier (confirmed directly: an iOS build failed instantly with "used its iOS builds from the Free plan," while an Android build on the same account, same month, queued and completed normally with only a "90% of credits used" warning). Android also has none of iOS's Keychain/certificate-signing complexity — EAS auto-generates and manages a Play-App-Signing-style keystore with no manual cert/provisioning-profile dance.

`eas.json` build profiles: add an explicit `"android": {"buildType": "apk"}` override on an internal-distribution profile (e.g. `preview`) to get a **directly-installable APK** — EAS gives back an install link + QR code that installs straight onto a test device, no Play Console involved at all. This is the fast path to a device build for taking real screenshots while Play Console setup is still in progress. The `production`/store profile should stay on the default **AAB** (Android App Bundle) output, since that's what Play Store actually requires for a real submission — an AAB is not directly installable.

## Android Step 3 — Google Play service account (the Android equivalent of the App Store Connect `.p8` key)

1. Google Cloud Console → create/select a project → enable **`androidpublisher.googleapis.com`** ("Google Play Android Developer API" — note the exact API name; other similarly-named APIs won't work, and `eas submit` will fail with a `PERMISSION_DENIED` error that conveniently includes the exact enable URL to click).
2. IAM & Admin → Service Accounts → create one, then Keys → Add Key → Create New Key → JSON.
3. ⚠️ **Newer Google Cloud accounts (2024+) — even personal ones with no formal Workspace org — may hit "Service account key creation is disabled."** Google now auto-creates a lightweight organization behind personal accounts specifically to hold default "Secure by Default" security policies. Fix, in Cloud Shell (no local install needed):
   ```
   gcloud organizations list                      # find the org ID
   gcloud resource-manager org-policies disable-enforce iam.disableServiceAccountKeyCreation --project=<PROJECT_ID>
   ```
   **Do not use `gcloud org-policies delete`** for this — it looks like it works (returns success) but only clears an override, which reverts the policy to the organization's *default*, and for these baseline constraints the default itself is still enforced. `disable-enforce` is the actual fix; it writes an explicit "not enforced" policy.
4. Grant the service account access in Play Console — **two independent, both-valid paths, try either**:
   - Setup → API access (link the Google Cloud project if not already linked, find the service account, grant **App permissions**).
   - **OR**, if "Setup"/API access doesn't appear at all even for a confirmed account Owner (see the troubleshooting note below): invite the service account's email address **directly as a regular user** via Users and permissions. This is a real, separate mechanism that achieves the same result and successfully bypassed an otherwise-unresolved Setup-visibility problem in practice — try this first if Setup is missing, rather than continuing to hunt for it.
5. Required app permissions for automated submission to actually work (fastlane supply / `eas submit`): **View app information** (read-only), **Edit and delete draft apps**, **Release to production, exclude devices, and use Play App Signing**, **Release apps to testing tracks**, **Manage testing tracks and edit tester lists**, **Manage store presence**.
6. Save the JSON key outside git (e.g. `secrets/google-play/service-account.json`, gitignored) and point `eas.json`'s `submit.production.android.serviceAccountKeyPath` at it, with `track: "internal"` as the default (don't default straight to `production`).

### If "Setup" / API access is missing even though you're the confirmed account Owner

This happened on a real account and took a while to diagnose. Two separate real causes were found, in the order they came up — check both, and don't assume it's a permissions-role problem alone:

- **The account's own permission role might genuinely be capped** (e.g. shown as "View app information (read-only)" under Users and permissions for your own login) — if there's an editable "Admin (all permissions)" option, select and save it.
- **The Play Console "Developer name" on the account may not match the actual legal owner's name** — e.g. left over from a different, earlier project. This is a very plausible trigger for Google's account identity verification to stall, which appears to gate admin-level account features like Setup/API access without a clear error message pointing at the real cause. Fix: correct the developer name in the developer profile to the real legal name and resubmit for Google's review (can take hours to a few days) — but don't block on this resolving: **try inviting the service account as a direct user first** (Step 3.4 above), which worked without needing to wait for identity verification to clear.

## Android Step 4 — Android Developer Verification (separate, newer Google policy — not Play Console app setup)

A 2026 Google policy (announced July 2026, enforcement deadline September 30, 2026) requiring registration of package names + signing-key certificate fingerprints, for anti-fraud — distinct from everything above.

- When asked to choose **"distribute exclusively outside Google Play"** vs. **"distribute on and outside Google Play"**: choose **"on and outside Google Play"** if using Play Store at all (even alongside direct/sideload distribution for testing) — this keeps everything under the existing Play Console account with no separate Android Developer Console account needed. The "exclusively outside" option is only for developers who never touch Play Store.
- The listed "Fingerprint" / "Add key" UI on this page is about the **app's signing certificate** (proves a build genuinely came from you) — a completely different concept from the Google Cloud service account JSON key from Step 3, easy to conflate since both are called "keys." If EAS-managed builds are already in place, the relevant fingerprints are usually auto-detected and show "Verified" already; "Add key" is only for registering an *additional* separate signing certificate, not needed for the normal case.

## Android Step 5 — Play Store listing assets

- **Screenshots**: max **2:1 aspect ratio**. iOS screenshots (commonly ~19.5:9 ≈ 2.17:1, e.g. 1290×2796) **exceed this and won't upload as-is** — and even if cropped to fit, they'd still show Apple's status bar chrome, not an Android device. Take real screenshots on an Android device instead (the sideloaded APK from Step 2 is the fast way to get a build on a device for this, no Play Console needed first).
- **Hi-res icon**: 512×512, 32-bit PNG with alpha.
- **Feature graphic**: 1024×500, PNG or JPEG, 24-bit (**no alpha**) — a promotional banner distinct from the app icon, shown at the top of the store listing.
- **Privacy policy URL**: same lesson as Apple's App Privacy — Play Console's Data Safety section wants a URL that reads as an actual formal policy document (sections: what's collected, third parties, children's privacy, data deletion, contact, effective date), not a one-paragraph blurb folded into a general support page. Worth a dedicated page.
- Short description: 80 characters max. Full description: 4000 characters max (same limit as Apple — the same copy can usually be reused across both stores with no platform-specific rewrite needed, if nothing in it names Apple/iOS specifically).

## Reusable secrets pattern

- **GitHub**: one fine-grained PAT per repo, stored as a Codespaces secret — not a token regenerated and dropped into a scratch file every session.
- **App Store Connect**: one team-scoped `.p8` API key can be reused across every app under the same Apple Developer team; only the app ID, bundle ID, and repo-specific secrets change per project.
- **Google Play**: one service account JSON key can similarly be reused across multiple apps under the same Play Console developer account — grant it App permissions for each additional app individually (Step 3.4/3.5 above), no need to create a new Google Cloud project or service account per app.
