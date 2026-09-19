# Bookrest — developer notes

A native SwiftUI client for [Audiobookshelf](https://www.audiobookshelf.org), for
iPhone, iPad, Mac and CarPlay.

## First run

```sh
xcodegen generate        # regenerates Bookrest.xcodeproj from project.yml
open Bookrest.xcodeproj
```

Set your team in **Signing & Capabilities** before building to a device. The iOS
target requests the **CarPlay Audio** entitlement (`com.apple.developer.carplay-audio`),
which must be enabled on the provisioning profile for `com.bookrest.app`.

## Layout

```
project.yml                     XcodeGen source of truth — edit this, not the .xcodeproj
Bookrest/                       App target (iOS + iPadOS + macOS, one target)
  App/                          Entry point, dependency container, scene wiring
  Features/                     Onboarding, Home, Library, Detail, Search, Downloads,
                                Settings, Player
  Components/                   Shared views and formatting
  CarPlay/                      CarPlay scene delegate and template coordinator
Packages/BookrestKit/           Local Swift package, no UI
  Sources/ABSClient/            API models, HTTP transport, auth, URL building
  Sources/BookrestCore/         Playback engine, downloads, offline store, progress sync
  Tests/                        Tests covering decoding, timeline maths and progress merge
```

The package holds everything that isn't SwiftUI, which is what makes it testable from
the command line (`swift test`) without a simulator.

## How streaming works

Audiobookshelf exposes three routes with different authentication, and Bookrest uses
each where it fits:

| Route | Auth | Used for |
| --- | --- | --- |
| `/public/session/{id}/track/{n}` | none | direct play — **preferred** |
| `/hls/{id}/…` | none | transcoded play |
| `/api/…?token=` | JWT in query | covers, and direct-play fallback |

Both playback routes are unauthenticated (guarded by an unguessable session id), so
`AVPlayer` needs no credentials on its byte-range or HLS segment requests. That avoids
the undocumented `AVURLAssetHTTPHeaderFieldsKey` that most media apps reach for, and
means seeking and background playback don't depend on header injection working.

Downloads take the opposite route: a background `URLSession` can send a real
`Authorization` header, so no token ever appears in a downloaded URL.

## Reliability notes

These are the decisions that matter if you change this code later.

- **Token refresh is single-flight.** Servers from 2.26 issue short-lived access
  tokens. A burst of concurrent 401s produces exactly one `/auth/refresh` call
  (`SessionStore`); everyone else awaits it. Older servers issue a non-expiring
  `token` and are handled on the same path.
- **Session syncs are never retried automatically.** Replaying one would double-count
  `timeListened` in the server's statistics. `RetryPolicy.never` is deliberately not
  called `.none`, because `policy: .none` silently parses as `Optional.none`.
- **The device is authoritative for position while offline.** Local writes are flagged
  `needsSync` and survive any server merge until they upload; server positions only
  win when they're newer *and* nothing local is pending.
- **Multi-file books use one continuous timeline.** `PlayerEngine` maps absolute item
  time onto `AVQueuePlayer`'s per-file clock. Seeks that cross a file boundary rebuild
  the queue, because an `AVPlayerItem` can't be re-enqueued once consumed.
- **Playback failures self-heal twice.** The first retry re-requests the session (fixes
  an expired one); the second asks the server to transcode (fixes a codec AVFoundation
  can't decode).
- **Resume position falls back to the server's.** A local position always wins, but
  when there is none — fresh install, or before the first progress refresh lands — the
  playback session's own `currentTime` is used. Returning 0 there silently restarts a
  part-finished book, which is what this originally did.
- **Items flagged `isMissing` fail before a session is opened.** Audiobookshelf will
  happily open a playback session for an item whose files are gone and then 404 every
  track, which would otherwise surface as two silent recovery attempts and a generic
  error.
- **The audio session category is negotiated, not assumed.** `.longFormAudio` routing
  policy is only valid with the playback category, default mode and no options.
  Pairing it with `.spokenAudio` throws `-50`, and because that left the session
  unconfigured, `AVPlayer` on iOS parked at `waitingToPlayAtSpecifiedRate` forever —
  an endless spinner with no error. `AudioSessionController` now tries
  `.spokenAudio` → `.default/.longFormAudio` → `.default` and reports whether any
  succeeded; `PlayerEngine.load` refuses to continue if none did. macOS has no
  `AVAudioSession`, so this was invisible there.
- **Never force a forward buffer.** `preferredForwardBufferDuration = 60` with
  `automaticallyWaitsToMinimizeStalling` stops playback starting until 60s of audio is
  buffered. On a fast connection that's a second; on a phone over cellular it's an
  endless spinner. Left at 0 (automatic) — AVFoundation starts promptly and keeps
  reading ahead by itself.
- **Seeks always carry a tolerance.** `toleranceBefore/After: .zero` forces
  sample-exact seeking, which on a multi-hour compressed file over HTTP can take
  minutes or never return — resuming a book ten hours in hung indefinitely. Resume
  uses ±1s, user seeks ±0.25s; both are inaudible in speech. Never set zero here.
- **Switching books doesn't wait on the outgoing session.** Closing the previous
  server session is fire-and-forget; awaiting it put a network round trip in front of
  every switch. Overlapping prepares are cancelled so a slow earlier request can't
  replace the book the user just picked.
- **A stalled start times out.** `startLoadWatchdog` fails the load after 25s if the
  clock never advances, so an unreachable host or an item stuck short of
  `.readyToPlay` runs the recovery path (re-request the session, then ask for a
  transcode) and only reports an error once that's exhausted.
- **The mini player uses `tabViewBottomAccessory` on iOS 26.** A `safeAreaInset` on a
  `TabView` draws over the tab items rather than reserving space above them. The
  accessory content deliberately has no background of its own — the system supplies
  the glass container.
- **Callbacks from system frameworks are never assumed to be main-thread.**
  `MPMediaItemArtwork` invokes its request handler on a private MediaPlayer queue. A
  closure built inside a `@MainActor` type inherits that isolation and the Swift
  runtime traps on entry, which crashed the app on every playback start — on macOS,
  iOS and CarPlay alike. `makeArtwork` is `nonisolated`, and remote-command and
  CarPlay Now Playing handlers are registered `@Sendable` and hop through
  `onMainActor`. Keep it that way: `NowPlayingIsolationTests` turns a regression into
  a compile error.
- **Playback start waits for item readiness, not a seek callback.** `PlayerEngine`
  records a `pendingStart` and applies it when the current item reports
  `.readyToPlay`. Driving it from the initial seek's completion handler looks
  equivalent and works on local files, but on a streaming item that isn't ready the
  callback may never arrive — playback then sits at 0s with the transport showing
  "Play".
- **A single play/pause button must call `playOrToggle(item:)`.** `play(item:)`
  resumes but never pauses, so a button whose label says "Pause" would do nothing.
- **The offline index is reconciled against disk at launch.** Files vanish when the app
  is offloaded or a backup is restored, and claiming a book is playable when it isn't
  fails far worse than re-downloading it.
- **Downloads carry their routing in `taskDescription`.** A background transfer can
  outlive the process, so the delegate must be able to identify a finished file after a
  cold relaunch.

## Build status

| Target | State |
| --- | --- |
| macOS app | builds and links (`BUILD SUCCEEDED`) |
| iOS app | builds and links, CarPlay framework included |
| `BookrestKit` | builds, tests pass |

Zero warnings on either platform.

```sh
cd Packages/BookrestKit && swift test
xcodebuild -project Bookrest.xcodeproj -scheme Bookrest \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

### iOS asset catalogue needs a simulator runtime

There are no iOS simulator runtimes installed on this machine, and Xcode 26's
`actool` refuses to compile an asset catalogue for `iphoneos` without one:

```
error: No available simulator runtimes for platform iphonesimulator.
       SimServiceContext supportedRuntimes=[]
```

This is environmental, not a code problem — the iOS build succeeds once the catalogue
is out of the way, and the macOS build compiles the same catalogue fine. Install a
runtime from **Xcode → Settings → Components** and it clears.

## Verified against a live server

Tested against Audiobookshelf 2.36.0 (479 books, 52 series, 87 authors, 161 progress
records), driving the real client code rather than curl:

- Login returns `accessToken` + `refreshToken` with `x-return-tokens`; `POST
  /auth/refresh` with `x-refresh-token` rotates both and the new token authenticates.
  Access tokens last one hour here, so the refresh path is load-bearing.
- Direct play chosen for `audio/mp4`; the unauthenticated
  `/public/session/{id}/track/{n}` route served **HTTP 206** with `Accept-Ranges:
  bytes`, so seeking works with no credentials on the request.
- Forced transcode returned a valid `#EXTM3U` playlist from `/hls/…`, also
  unauthenticated.
- A two-file book reported contiguous track offsets; the boundary at 15639s maps
  `15638s → track 1`, `15639s → track 2 offset 0`.
- Series and author filters returned exact counts (8 of 8 both times).
- The macOS app signed in from the Keychain under App Sandbox and merged all 161
  server progress records (62 in progress, 95 finished, 0 left flagged for sync).
- `PlayerEngine` streamed real audio: decode and advance, pause/resume, a seek across
  the file boundary landing within a second of target, and 2× rate applied correctly.
- With artwork attached, playback ran clean and the Now Playing artwork handler served
  images on demand from a background queue.

Three bugs were found and fixed this way: the artwork isolation crash, the
resume-position fallback, and the missing-files guard. All three are covered by tests.

## Shipping to TestFlight

```sh
export TEAM_ID=XXXXXXXXXX
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/AuthKey_XXXX.p8
./Scripts/testflight.sh
```

The script archives, exports a signed `.ipa`, validates it, and uploads. Build numbers
default to a UTC timestamp so they always increase. Secrets are read from the
environment and never written into the repo.

Bundle ID `com.giantmushroom.bookrest`. Builds with and without CarPlay have both
uploaded and processed as VALID.

### Signing is manual, deliberately

Xcode's automatic cloud signing fails at export with `Cloud signing permission error` /
`No profiles for 'com.giantmushroom.bookrest' were found`, even though the same API key
can create the assets directly. So the signing assets were provisioned through the API
and `ExportOptions.plist` names them explicitly:

- An Apple Distribution certificate, expires 2027-09-02
- Profile **Bookrest App Store** (`IOS_APP_STORE`), expires 2027-09-02

Both are installed on the release machine. When either expires, recreate via the API rather
than switching back to automatic signing.

### Background modes

`UIBackgroundModes` is **`audio` only**. Background downloads run on a background
`URLSession`, which requires no background mode, and nothing registers
`BGTaskScheduler` work — declaring `processing` without
`BGTaskSchedulerPermittedIdentifiers` fails App Store validation with error 90771.

### CarPlay builds

CarPlay is granted on this App ID. Build with it using:

```sh
CARPLAY=1 ./Scripts/testflight.sh
```

Without that flag the build signs against `Bookrest-iOS.entitlements`, which omits the
entitlement — useful if the profile ever loses it. The CarPlay code ships either way;
the scene simply never connects without the entitlement.

**Don't trust the API's capability name here.** `GET
/v1/bundleIds/{id}/bundleIdCapabilities` reports this App ID's CarPlay grant as
`CARPLAY_PLAYABLE_CONTENT`, which suggests the deprecated MPPlayableContent
entitlement. It isn't — the provisioning profile Apple issues actually contains
`com.apple.developer.carplay-audio`, which is what the modern template API needs. The
profile's entitlement list is the source of truth; the capability label is stale.
Enabling the capability must be done in the developer portal UI — the API rejects both
CarPlay capability types as invalid values.

The archive itself is already verified: it builds unsigned, compiles the icons into
`Assets.car`, declares the CarPlay scene, and links CarPlay.framework.

### Immersive theme

Off by default; a toggle in Settings. `ThemeController` pulls the cover of whatever is
playing, `PaletteExtractor` reduces it to a 64px thumbnail and histograms it at 5 bits
per channel, and the result tints the app and washes the player background.

Histogrammed rather than averaged — averaging a cover reliably produces grey-brown. The
accent is scored on saturation and mid-luminance rather than pixel count, so a cover's
one vivid colour wins over its large dull areas. `PaletteTests` asserts against real
covers that the accent keeps saturation and the background stays dark enough for light
text.

## Not yet verified

- Downloads have not been exercised against a real file.
- Podcast downloads are modelled but the UI only exposes download for books.
- No websocket connection, so another device's progress appears on next refresh
  rather than live.
