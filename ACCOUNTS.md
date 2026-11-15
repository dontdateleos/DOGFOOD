# Accounts: the plan

Not built yet. This is what we'd build, in what order, and the rules Apple adds once health data
leaves the phone.

## What an account is for

At first, one thing: **your data survives a lost phone and appears on a second device.** Today
the device is the only copy (Settings → Backup & Restore says so), and the export file is the only
backup. Sharing with a coach, an Android or web version, and server-side features all come later.
They are reasons to build it the way described here, not part of the first release.

## Ground rules

- **Optional, always.** The app works fully signed out, as it does today. Signing in adds backup
  and sync. Apple rejects apps that demand a login for features that don't need one (guideline 5.1.1).
- **Local first.** The phone's copy stays the one the app reads, so it is instant and works offline.
  The account is a copy kept in step behind it, never a server the app waits on.
- **Delete from inside the app.** Any app that lets you make an account must let you delete it, and
  its data, from inside the app (5.1.1(v)). This goes in Settings in the first release, not later.
- **Not iCloud.** Apple doesn't allow health data in iCloud (5.1.3), which rules out CloudKit even
  though it would need no sign-in at all. The data goes to our own backend.
- **Never ads, never sold.** Health data can't be used for advertising or passed on (5.1.3). The
  privacy policy and the App Store privacy label say so.

## How it fits the code

Everything the app saves already goes through one place: `window.storage` in `index.html`, with
`get`, `set`, `list` and `delete` over named keys. The key families are `entry:` (morning check-ins),
`training:` (sessions), `weekplan:`, `weekmeta:`, `goals:`, `injury:`, `bodymetrics:`, `settings:` and
a few smaller ones. A year of use is about 750 keys and 0.8MB. Each key is already a small,
independent record, a day or a week, so **sync can work key by key** without changing any feature code.

1. **Note every change.** `storage.set` and `storage.delete` stamp the key with the time it changed,
   in a sidecar index. A delete leaves a marker, so a deletion syncs instead of being undone by the
   other device.
2. **Push and pull.** Signed in, the app sends keys changed since the last sync and fetches keys the
   server has changed. This runs on open, on return to the app, and a few seconds after a save.
3. **Conflicts: newest edit wins, per key.** The keys are small (one day's check-in, one week's plan),
   so two devices rarely edit the same one at the same moment. When they do, the later edit wins.
   This can be refined later, for example by merging a session log set by set.
4. **What doesn't sync.** Device-only state stays local, for example:
   - which sections are collapsed;
   - the mark's animation preferences;
   - text size;
   - haptics;
   - the Apple Health connection (each phone grants its own).

   This needs an explicit allowlist of the key families that do sync.
5. **First sign-in.** An empty account takes everything on the phone. An account that already has
   data (a second device) gets a choice:
   - keep both, merged by newest edit;
   - replace this phone with the account;
   - replace the account with this phone.

   The choice shows how many days each side has. The export file stays as a backup.

## Backend

**Recommended: Supabase.** It's a Postgres database with sign-in built in (Sign in with Apple and
email links included), it has a JavaScript client that runs inside the web app as it is, and its
free tier covers this many times over.

- One table: `records(user_id, key, value jsonb, updated_at, deleted)`.
- Row-level security, so each person can only read and write their own rows.
- Account deletion is one call that removes the user and their rows.
- A real database also leaves room for later: coach sharing, a web dashboard, and moving the Oura
  sign-in to the server.

Firebase would also work. Rolling our own server means more to run, for no gain at this stage.

**Optional: end-to-end encryption.** The app could encrypt each value before upload with a key
derived from a passphrase, so not even the backend could read it. The cost:
- forgetting the passphrase loses the cloud copy;
- server-side features (coach sharing, a web view) become much harder.

Worth deciding before launch, because adding it later means re-uploading everything.

## Sign-in

- **Sign in with Apple** first: one tap on iPhone, no password, and it can hide your email.
- **Email link** (a link that signs you in, no password) for the browser version and other devices.
- If Google sign-in is ever added, Apple requires Sign in with Apple alongside it (4.8). It's
  already there.

Both need the app to catch a sign-in link on return: a custom URL scheme or universal link. That is
the same piece Oura's sign-in needs in the native app, so building it once unlocks both.

## Order of work

1. **Change stamps.** Add the sidecar index and delete markers to `window.storage`. Small and
   invisible, and it can ship before anything else.
2. **Backend setup:** Supabase project, `records` table, security rules, Sign in with Apple
   (needs a Services ID in the Apple Developer account) and email links.
3. **Sign-in screen** in Settings: sign in, signed-in state, sign out, delete account.
4. **Sync engine:** push and pull, the newest-edit-wins rule, the allowlist, and the first sign-in
   choice.
5. **Store paperwork:**
   - privacy policy updated for cloud storage;
   - App Store privacy label: Health & Fitness, linked to you, not used for tracking;
   - the HealthKit explanation in review notes.
6. **TestFlight with two devices**, then release.

## Open questions

- Is an account just backup and sync, or should another person (a coach) ever see your data?
  If a coach might, rule out end-to-end encryption now.
- Does the browser version get accounts too, or only the iPhone app? Supabase handles both. The
  question only changes which sign-in methods come first.
