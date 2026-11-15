# Dogfood on iPhone (TestFlight)

The iPhone app is the same `index.html` running inside a [Capacitor](https://capacitorjs.com) shell, with
two native additions: **HealthBridge**, a small Swift plugin that reads Apple Health directly, and
**Haptics**, which plays the Taptic Engine for the web app's taps, swipes and wheels.

```
index.html, sw.js, icons, splash   the web app (unchanged; still works in a browser)
tools/build-web.mjs                copies those into www/ for the app bundle
capacitor.config.json              app id com.touringgroup.dogfood, name "Dogfood"
ios/App/App.xcodeproj              the Xcode project (Swift Package Manager, no CocoaPods)
ios/App/App/HealthBridgePlugin.swift   the HealthKit reader
ios/App/App/HapticsPlugin.swift        the Taptic Engine, for taps, wheel ticks and saves
ios/App/App/MainViewController.swift   registers the plugin with Capacitor
ios/App/App/App.entitlements           HealthKit capability
```

## Build and send to TestFlight without a Mac

This works the same way Rooms does: GitHub's Macs build, sign and upload the app.

- **`iPhone app`** (`.github/workflows/ios.yml`) runs on every push to main that touches the app.
  - It compiles the app for the simulator, launches it and takes a screenshot.
  - If it goes green, the app builds.
- **`Send to TestFlight`** (`.github/workflows/testflight.yml`) is run by hand from the Actions tab.
  - It signs with a certificate and profile it makes itself through the App Store Connect API (`tools/asc-sign.mjs`).
  - Then it archives and uploads. The build reaches TestFlight about 15 minutes later.

One-time setup:
1. **Add three repository secrets** in GitHub → this repo → Settings → Secrets and variables → Actions:
   - `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`;
   - the same App Store Connect Team Key (Admin role) that Rooms uses.
2. **Run "Send to TestFlight" once.** It registers the bundle ID `com.touringgroup.dogfood` with HealthKit
   switched on. If the app doesn't exist in App Store Connect yet, it stops and tells you so.
3. **Create the app:** App Store Connect → Apps → + → New App:
   - iOS, named **Dogfood**;
   - bundle ID `com.touringgroup.dogfood`;
   - any SKU, for example `dogfood`.
4. **Run "Send to TestFlight" again.** Every run after that uploads a new build, numbered 100 + the run number.

Certificates are shared by every app on the team, and Apple allows only two distribution certificates.
`asc-sign.mjs` never revokes a certificate behind a build that's in App Review for any of the team's
apps, and revokes nothing while there's still room. (Rooms' own copy only protects Rooms' builds,
which only matters once a Dogfood build is in App Store review rather than just on TestFlight.)

## The lock-screen widget

`ios/App/DogfoodWidget` is a WidgetKit extension showing Charge, where it went today, and the next
session, on the lock screen (circular, rectangular and inline) and the home screen (small). The app
hands it the numbers through an App Group (`WidgetBridgePlugin.swift`), whenever it works them out.

Apple's API can't create an App Group, so it's set up by hand once, at developer.apple.com →
Certificates, IDs & Profiles:
1. **Identifiers → + → App Groups**: description "Dogfood", identifier `group.com.touringgroup.dogfood`.
2. **Identifiers → com.touringgroup.dogfood → App Groups → Configure**: tick the group, then Save.
3. The same for **com.touringgroup.dogfood.widget**, which "Send to TestFlight" registers on its
   next run.

Until both ids carry the group, "Send to TestFlight" builds the app without the widget, exactly as
before, and says so in its log. Once they do, the next run includes it.

## Build it on a Mac instead

You need Xcode 16 or newer, and a paid Apple Developer account.

1. `npm install`
2. `npm run ios:sync` copies the web app into the Xcode project. Run it after every change to `index.html`.
3. `npm run ios:open` opens Xcode, or open `ios/App/App.xcodeproj` directly.
4. In Xcode, select the **App** target and open **Signing & Capabilities**:
   - The **Team** is already set (M6AXSFYX2W, the Rooms team) and the bundle ID is `com.touringgroup.dogfood`.
   - Check that **HealthKit** is listed. If it isn't, click **+ Capability** and add HealthKit. The entitlements file is already in place.
5. Pick your iPhone as the run destination and press Run. On the first launch:
   1. Go to Settings → Apple Health → **Connect Apple Health**.
   2. Allow the data types.
   3. It reads the last 30 days.

## TestFlight

1. In App Store Connect, create the app with the same bundle ID.
2. In Xcode, set the version (1.0) and build number (1, then increase it on every upload).
3. Choose Product → Archive → Distribute App → App Store Connect → Upload.
4. When the build finishes processing, invite testers in App Store Connect → TestFlight:
   - **Internal testers** (up to 100 people on your team) can install straight away.
   - **External testers** need a short Beta App Review first. Apple will want:
     - a **privacy policy URL**;
     - a sentence on how health data is used: it's read only, stays on the device, and is never used for ads or shared.

## What it reads

Apple Health is the one source. Oura and Garmin aren't connected directly: their own apps write to
Health, and Dogfood reads it there. The plugin reads:
- **sleep**: one source per night, the one with sleep stages (the ring), so a ring and a watch worn
  to bed aren't added together. Wake time and minutes awake come from it.
- **heart rate**: resting heart rate is taken as the lowest 30 minutes asleep, because Oura and Garmin
  write plain heart rate rather than a resting figure. An Apple Watch's own resting figure is the
  fallback.
- **breathing rate** (Oura writes a nightly average)
- **wrist temperature** (Apple Watch only)
- **weight** and **body fat**: the day's first weigh-in from a scale that writes to Health (Withings), into Body metrics, never over a day you saved yourself
- **steps** and **active calories** (Health removes duplicates between devices)
- **running workouts**: a run recorded by two apps is kept once (the one with a distance)
  and its average heart rate, so the score can compare speed per heartbeat between runs

**HRV is not used.** Neither Oura nor Garmin shares it with Health, so the readiness score runs on
resting heart rate, sleep, breathing rate, training load and form. `HRV_ENABLED` in index.html
turns it back on, for example if an Apple Watch ever writes it.

The app fills in days you haven't logged yourself and never overwrites what you typed. Runs that Health
records are kept on the day (`appleRuns`) but not logged as sessions yet.

## Not done yet

- **Oura's direct connection has been removed.** Only the Shortcut relay used by the browser
  version is left.
- **Storage.** Data still lives in the web view's local storage. iOS rarely clears it for an installed app, but
  moving to native storage (Capacitor Preferences or SQLite) would make it permanent.
- **Updates.** Web changes reach the app when you run `npm run ios:sync` and upload a new build.
- **Icons.** The app icon is the mark at 1024px, written by `node tools/build-icon.mjs` along with the web icons.
  The launch screen is plain launch-curtain black, so the app opens straight into the curtain animation.
