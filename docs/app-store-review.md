# App Store submission notes

What goes into App Store Connect for Dogfood, and the answers to give. The privacy manifest
(`ios/App/App/PrivacyInfo.xcprivacy`) and `Info.plist` already say the same things in the
build itself.

## App Privacy ("nutrition label")

**Data collection: "No, we do not collect data from this app."**

Apple counts data as *collected* only when it leaves the device to the developer or a third
party. Dogfood has no server, no account, no analytics and no advertising. Everything,
including what it reads from Apple Health, stays in the app's storage on the iPhone. A backup
leaves the phone only when the user saves one through the share sheet, to a place they choose.

- Tracking: none. `NSPrivacyTracking` is false and there are no tracking domains.
- Required-reason APIs: `UserDefaults`, for the app's own settings (CA92.1) and to hand
  today's Charge to the widget through the app group (1C8F.1).

## Apple Health

- Read only. The app never writes to Health.
- Types read: sleep analysis, heart rate, resting heart rate, respiratory rate, sleeping wrist
  temperature, body mass, body fat percentage, VO2 max, step count, active energy, workouts.
- Purpose string (`NSHealthShareUsageDescription`) names each of these and says the data stays
  on the iPhone.
- Health data is not used for advertising, sold, or shared, which is what guideline 5.1.3 asks.

## Notifications

Local only, and off until the user taps **Remind me** on the bedtime note. Then one
notification is scheduled before bedtime on nights before a hard session. Nothing is pushed
from a server.

## Encryption

`ITSAppUsesNonExemptEncryption` is false: the app makes no network requests of its own.

## Notes for the reviewer (paste into "Notes" under App Review Information)

> Dogfood is a training app for lifting and running. There is no login.
>
> To see it working without Apple Health data: open the app, tap the mascot on the first
> screen to do the morning check-in, then open Workouts and log a session (tap a day on the
> week strip, then a set). The Charge score, its ring around the mascot, the Build tab's
> Training lines and the lock-screen widget all fill in from the check-in and the session.
>
> Apple Health is optional. When connected, Dogfood reads sleep, heart rate and workouts to
> estimate how recovered the user is. It never writes to Health and nothing leaves the device.
>
> The Live Activity appears on the lock screen once a set is ticked during today's session.

## Still to do in App Store Connect

- Fill in the App Privacy answers above.
- Add the reviewer notes above.
- Age rating: no objectionable content (4+); it gives training advice, not medical advice.
- Category: Health & Fitness.
