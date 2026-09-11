---
name: new-mobile-app-setup
description: Use at the very start of a new Expo/React Native mobile app project — or when setting up its shipping pipeline for the first time — to configure GitHub push access, App Store Connect API access, and an Xcode Cloud (not EAS Build) build pipeline. Covers the concrete gotchas hit while shipping TaskMeal.
---

# New mobile app setup (Expo → Xcode Cloud → App Store Connect)

This process was learned end-to-end while building and shipping TaskMeal (an Expo/React Native app), across a GitHub Codespaces sandbox that could only push to one repo by default. Follow it in order for any new app of this shape. Don't skip Step 0 — every later failure in this list traces back to a question that wasn't asked up front.

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

## Reusable secrets pattern

- **GitHub**: one fine-grained PAT per repo, stored as a Codespaces secret — not a token regenerated and dropped into a scratch file every session.
- **App Store Connect**: one team-scoped `.p8` API key can be reused across every app under the same Apple Developer team; only the app ID, bundle ID, and repo-specific secrets change per project.
