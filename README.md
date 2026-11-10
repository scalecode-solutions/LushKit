# LushKit

Swift client for **mvLush**: the Connect transport for toys and sharing, the
`/live/v1` socket for live control, the Lovense Bluetooth layer, and the UI.
The host supplies identity and a token provider and never logs in through the
kit. Same shape as GarageKit.

iOS 26, Swift 6 (strict concurrency). Depends on connect-swift and
swift-protobuf only.

## What a host does

```swift
import LushKit

// 1. Build it inert (no socket, no requests, nothing on disk).
let config = LushConfig(
    baseURL: URL(string: "https://example.app")!,
    currentUserID: myUserID,
    tokenProvider: { await auth.accessToken() },     // the host's own token
    deviceName: UIDevice.current.name
)
let engine = LushEngine(config: config)
let bluetooth = LushBluetooth(
    engine: engine,
    beginSystemDialog: { /* host: a system prompt is about to show */ },
    endSystemDialog: { /* host: it's gone */ }
)

// 2. Show it inside the host's own NavigationStack.
NavigationStack {
    LushView(engine: engine, bluetooth: bluetooth)
        .navigationTitle("…")                        // the host's title
        .toolbar { NavigationLink { LushOwnerView(engine: engine) { } } label: { Image(systemName: "gearshape") } }
}
.task { engine.start() }                             // 3. run only while on screen
.onDisappear { engine.stop() }
.onChange(of: scenePhase) { _, phase in              // 4. and only in the foreground
    if phase == .background { engine.stop() } else if phase == .active { engine.start() }
}

// 5. Sign-out.
bluetooth.shutdown()
engine.wipeLocalStore()
```

### The rules behind that

- **Silent unless it's on screen.** A stopped engine holds no socket and makes
  no requests. On a day nobody opens the screen, the server never hears from
  the phone. `stop()` also stops every toy connected to this phone.
- **No notifications.** The kit never posts one and never asks for permission
  to. Whatever invites someone to play happens in the host.
- **Bluetooth is asked for only when the user taps Connect.** Nothing touches
  CoreBluetooth before `LushBluetooth.scan()`. iOS makes the app inactive while
  its permission prompt is up; `beginSystemDialog` / `endSystemDialog` let a
  host that locks on inactive tell the prompt from the user leaving. The host
  app needs `NSBluetoothAlwaysUsageDescription` in its Info.plist.
- **Everything the kit writes on the phone is removed by `wipeLocalStore()`:**
  two `UserDefaults` keys (the install id, and the release mode per user).
  It keeps no database.
- **Screens live in the host's navigation.** `LushView` and `LushOwnerView` are
  pushed content; the control is a pushed destination (it hides the bar and
  brings its own back button, because the whole screen is the slider). Sheets
  are used only for short tasks (connect a toy, share, design a pattern).
  The kit never sets the host's title.
- **Wording** on the home screen comes from `LushAppearance` (neutral
  defaults).
- **People** (names and avatars for sharing) come from mvLush's own contact
  list, which is the host's social graph projected by the server, the same
  way GarageKit gets them.

## Safety, on the phone

These are pinned by tests (`Receiver.decide`, `LovenseProtocolTests`,
`EngineStateTests`):

- **Silence stops the toy.** A level lasts `hold_ms` (3 s, capped at 5 s here)
  unless refreshed; then the phone stops the toy itself.
- **Stop always applies:** never late, never refused, even while paused.
- **Her stop wins.** `pause(hwKey:)` stops the toy and refuses everything but
  Stop until she resumes.
- **A command that arrives late is dropped**, as is anything without deadlines.
- **Socket lost → every toy on this phone stops.**
- **The toy protects itself too.** On connect the kit sends
  `AutoSwith:On:Off;`: the toy stops on its own if the Bluetooth link drops,
  and doesn't resume when it returns. That covers a phone that is suspended or
  out of range, when no app code is running.
- **Stop is zero levels**, not a word: the Lovense protocol has no `Stop;`.
  A toy is never sent a number outside its range.

## Bluetooth

`LushBluetooth` scans by name (`LVS-…`), connects, finds the write / notify
characteristics (known service families first, then by characteristic
properties for firmware nobody has seen), asks `DeviceType;` for the model and
address, and puts the toy in service with `engine.host`. A dropped link takes
it out again. The toy's address is its key on the server, so it keeps its
identity across phones and reinstalls; a toy that never answers `DeviceType;`
is keyed by this phone's id for it.

The string protocol lives in `Bluetooth/LovenseProtocol.swift`, free of
CoreBluetooth so tests can pin it. Reference:
<https://docs.buttplug.io/docs/stpihkal/protocols/lovense/>.

**Not yet proven on hardware** (written from the protocol notes and the May
2026 prototype; first real-toy test pending): preset numbers
(pulse 1 · wave 2 · fireworks 3 · earthquake 4), `AutoSwith` on a Lush 4, and
rotation direction on a Nora.

## Not built

- **A session that survives the screen locking.** Today leaving the foreground
  ends it. Keeping one alive is a host setting (off by default, like keeping a
  call), and needs something to keep the app running; not decided.
- Audio sync (the prototype's mic → level stream).

## LushLab

`Demo/LushLab` is the host used for development: the same wiring as above,
real mvServer login through MvAuth, a Production / Local picker.

- **Simulator:** no Bluetooth, so it can host a `SimulatedToy` (Manage → Lab).
- **Real phone against the local stack:** choose Local and enter the Mac's
  network name; the Mac must publish mvServer's and mvLush's ports on the
  network (`LUSH_BIND=0.0.0.0` for mvLush).
- **Automation (Debug builds):** `LUSHLAB_USER` + `LUSHLAB_TOKEN` in the
  environment skip the login screen with a token from mvLush's
  `cmd/minttoken`, e.g. to run two simulators from a script:
  `SIMCTL_CHILD_LUSHLAB_USER=… SIMCTL_CHILD_LUSHLAB_TOKEN=… xcrun simctl launch <sim> dev.scalecode.LushLab`.

Regenerate the project after changing `Demo/project.yml`: `cd Demo && xcodegen generate`.

## Tests

```sh
xcodebuild test -scheme LushKit -destination 'platform=iOS Simulator,name=<a simulator>'
```

The live suite runs only with a server and a token:

```sh
TOKEN=$(cd ../mvLush && go run ./cmd/minttoken "$KEY" "$(uuidgen | tr A-Z a-z)")
TEST_RUNNER_LUSH_TOKEN=$TOKEN TEST_RUNNER_LUSH_URL=http://localhost:6094 xcodebuild test …
```

## Generated code

`Sources/LushKit/Generated` comes from mvLush's protos:
`buf generate --template buf.gen.swift.yaml` (run in `../mvLush`).
