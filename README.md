# Snow Globe

A SwiftUI activity indicator made from Metal particles moving inside a glass sphere. At rest, a broad, gently circulating white cloud touches the glass. Rising effort adds color, sparkle, opposing currents, and collisions. Speech reshapes the particles into an audio waveform. Disconnecting lets them fall and settle at the bottom.

The package contains the complete animation from the Snow Globe prototype, including its tuned defaults, light appearance, HDR lighting, and reduced bloom at small sizes. The included macOS application is a consumer of the package's public API.

## Requirements

- **macOS 14+ or iOS/iPadOS 17+**, with a Metal-capable GPU.
- **Xcode 15+ / Swift tools 5.9+**. The source uses Swift 5 language mode.
- An HDR/EDR-capable display is needed to see overbright highlights. SDR displays work with available headroom of 1.
- No third-party dependencies, network connection, microphone permission, or speech voice is required by the package.
- The **demo's Speak button** uses the separately installed macOS **Jamie (Premium)** voice. This is demo functionality; consumers can feed speech from any audio source.

The macOS implementation and GPU regression suite are validated locally. The iOS library is build-checked; touch-device performance and physical iOS HDR appearance still need device evaluation.

## Open and run in Xcode

Clone the public repository, then open the included example project:

```sh
git clone https://github.com/swryder/Snow-Globe.git
cd Snow-Globe
open 'Snow Globe.xcodeproj'
```

Open **`Snow Globe.xcodeproj`** from this directory. Select the **Snow Globe** scheme and **My Mac**, then Run (⌘R). Test (⌘U) runs the package API and production Metal regression checks through the included test target.

The project references the Swift package at `.` as a **local package dependency**. The app compiles only the files in `Examples/SnowGlobeDemo`; it imports `SnowGlobe` and links the package product. There are no copies of the renderer or shaders in the application target.

To work on the library alone, open **`Package.swift`** in Xcode and select the **SnowGlobe** package scheme. The generated package scheme is also visible from the demo project. Select an iOS destination to build the library for iPhone/iPad; the included application target is macOS only.

The checked-in Xcode project is ready to use. `project.yml` is its reproducible [XcodeGen](https://github.com/yonaskolb/XcodeGen) definition; XcodeGen is needed only if you change the project layout and want to regenerate it:

```sh
xcodegen generate
```

## Add Snow Globe to another application

In Xcode, choose **File → Add Package Dependencies…** and enter:

```text
https://github.com/swryder/Snow-Globe.git
```

Choose **Up to Next Major Version**, starting at **1.0.0**, and add the **SnowGlobe** library product to your app target. The public package can be downloaded without GitHub authentication. Do not add `Sources/` or `Particles.metal` to the app's Compile Sources phase; Swift Package Manager supplies the code and shader resources.

For a Swift package consumer:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyAppComponents",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MyAppComponents", targets: ["MyAppComponents"])],
    dependencies: [
        .package(url: "https://github.com/swryder/Snow-Globe.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "MyAppComponents", dependencies: [
            .product(name: "SnowGlobe", package: "snow-globe")
        ])
    ]
)
```

The repository's SwiftPM identity is **`snow-globe`**; the library product and Swift import are **`SnowGlobe`**. Releases use semantic version tags, beginning with **`1.0.0`**.

For local development, you can instead use **Add Local…** in Xcode or `.package(path: "../Snow-Globe")` in a consumer manifest. Local package identity follows the lowercased checkout directory name, so adjust the consumer's `package:` argument if you rename that directory. The included example deliberately uses a local dependency on `.` so changes to the library are immediately available in the demo.

## Minimal SwiftUI integration

```swift
import SwiftUI
import SnowGlobe

struct AgentActivityView: View {
    @State private var effort: Float = 0
    @State private var connected = true

    var body: some View {
        SnowGlobeView(activity: effort, isConnected: connected)
            .frame(width: 280, height: 280)
    }
}
```

`activity` is normalized from **0 to 1**. Feed changes directly; the renderer supplies its own smoothing. Medium and large effort changes respond faster, while small changes keep the gentle organic motion. Keep the view's identity stable: repeatedly changing `.id(...)` or removing/reinserting it recreates the simulation and history.

The globe stays circular in a rectangular frame, using about 89% of the shorter dimension. It draws its own opaque, theme-matched background. Use `.frame(...)` or your layout container to resize it. Below 360 logical points in globe diameter, particle footprints, trail widths, and high-effort emission scale down to keep small globes from turning into white bloom.

## Defaults and controls

All presentation defaults are defined by **`SnowGlobeConfiguration.default`**. The demo initializes its tuning controls from this same configuration. Values are ordinary multipliers or normalized scalars: `0.30` means 30%, `3` means 300%.

| Setting | Default | Supported range / meaning |
| --- | --- | --- |
| `activity` (view input) | `0` | `0...1`, idle to maximum effort |
| `isConnected` (view input) | `true` | `false` drops particles into the bottom of the globe |
| `appearance` | `.dark` | `.dark`, `.light`, or `.automatic` from SwiftUI color scheme |
| `shape` | `.disc` | `.disc` or `.ring`; internal particle distribution only |
| `particleCount` | **10,000** | `10...33_600`; maximum admitted population at full effort |
| `particleSize` | **1.75×** | `0.5...20` |
| `idleSpeed` | **4×** | `0.5...4` |
| `trailLength` | **30%** | `0...1`; normal activity trails |
| `speakingTrailLength` | **50%** | `0...1`; used only in `.flowing` speech mode |
| `speechMode` | **`.live`** | Latest detailed waveform; `.flowing` is also available |
| Live speech trails | **Off** | Automatically forced to zero in `.live` mode |
| `speechExpression` | **100%** | `0...2`; zero disables speech motion and lighting |
| `flashFactor` | **300%** | `0...8`; voice illumination with EDR overdrive |
| Container | **Sphere** | Fixed; the discarded depth/flattening control is not exposed |

Idle uses only part of the particle budget; **10,000 is the full-effort limit**, not a guarantee of 10,000 visible particles at rest. The full simulation capacity remains allocated regardless of the budget slider.

The `*Range` static properties on `SnowGlobeConfiguration` expose supported tuning ranges. Out-of-range inputs are clamped when delivered to the renderer. Non-finite scalar settings fall back to defaults; a non-finite activity value becomes idle. Mutating a configuration does not immediately clamp its stored public values.

```swift
var settings = SnowGlobeConfiguration.default
settings.appearance = .automatic
settings.particleCount = 6_000
settings.particleSize = 2
settings.flashFactor = 4.5

// Use settings in your View body:
SnowGlobeView(activity: effort, configuration: settings)
```

Light appearance uses a subtly neutral glass interior, blue idle particles, and saturated active colors. Dark appearance retains white idle particles and a cool-dominant full spectrum at high effort.

## Connection state

Set `isConnected` to `false` when the agent disconnects. The particles already visible fall under gravity, slide against the glass, and settle to rest in a shallow bed. Their sparkle fades. Speech input is ignored during disconnection.

On reconnect, the particles lift back into the current corresponding to `activity`. **Set activity to zero when reconnecting if you want an idle arrival**, as the demo does:

```swift
func setConnection(_ value: Bool) {
    effort = 0
    connected = value
    if !value {
        meter.store(.zero, sessionActive: false)
        // Also stop your own audio playback here if appropriate.
    }
}
```

The package does not open a network connection or stop a consumer's audio player. `isConnected` is a visual state input.

## Synchronize speech

The package separates **audio playback** from **visualization**. Keep one `SpeechMeter` alive for a globe and supply samples timed to the audio currently being heard. The mailbox uses a lock and can be written from a metering worker without driving SwiftUI updates for every sample. It is not an allocation-free, hard real-time audio callback API; publish from a metering queue or timer, rather than doing file analysis on an audio render thread.

The two public speech types are:

- **`SpeechMeter`** — thread-safe mailbox for level, onset accent, detailed waveform, and session state.
- **`SpeechEnvelope`** — analyzes a local audio file into loudness/onset samples and detailed signed peak history. It loads the clip into memory; use bounded clips for long recordings.

### File playback example

Analyze each clip off the main thread, then sample using `AVAudioPlayer.currentTime` from a roughly 60 Hz timer while it plays. The relevant integration points are:

```swift
import AVFoundation
import SnowGlobe

let meter = SpeechMeter()                 // Retain this; share it with the view.
let envelope = try SpeechEnvelope(url: audioURL)
let player = try AVAudioPlayer(contentsOf: audioURL)

// Before starting playback:
meter.store(.zero, sessionActive: true)
player.play()

// In your playback timer (about 60 Hz):
let time = player.currentTime
meter.store(envelope.sample(at: time),
            waveform: envelope.waveform(at: time))

// In AVAudioPlayerDelegate completion, cancellation, or Stop:
meter.store(.zero, sessionActive: false)
```

Pass the same mailbox to the view:

```swift
SnowGlobeView(activity: effort, isConnected: connected, speechMeter: meter)
```

Do not derive visualization timing from when text is generated or when audio is synthesized. Use the playback clock so flashes and waveforms match what is audible. `Examples/SnowGlobeDemo/SpeechController.swift` is a complete example of playback, cancellation, metering, sentence preparation, and error reporting.

### Streaming or custom speech sources

Call:

```swift
meter.store(SIMD2(level, onsetAccent),
            waveform: signedPeaks,
            sessionActive: true)
```

The input contract is:

| Input | Format |
| --- | --- |
| Level | `Float` in `0...1`, perceived speech loudness |
| Onset accent | `Float` in `0...1`, strength of the current syllable attack |
| `signedPeaks` | Exactly **512 `SIMD2<Float>` pairs** spanning the latest **0.48 seconds** |
| Each peak pair | `.x` is a negative minimum in `-1...0`; `.y` is a positive maximum in `0...1` |
| Array ordering | **Oldest first, newest last**; the renderer presents new audio on the left, aging to the right |
| Session | `true` for the entire utterance, including sentence gaps; `false` on actual completion or cancellation |

A streaming implementation should maintain a rolling PCM peak buffer and publish this format at the playback position. The included file analyzer extracts signed extrema at approximately 1 ms resolution and uses a causal 3 ms peak window to preserve detail without averaging positive and negative samples away.

Empty or incorrectly sized waveform arrays become 512 zero pairs. Non-finite and out-of-range sample components are sanitized. **Live mode needs actual peak pairs**; a loudness envelope alone cannot provide a recognizable live waveform. For envelope-only sources, select `.flowing` and omit `waveform:`.

Omitting `sessionActive:` preserves the mailbox's previous session state. During a sentence gap, publish silence with the session still active. Explicitly end the session to trigger the fast return to normal motion; the speech influence loses about 90% within 190 ms and is effectively gone within 0.6 seconds. Removing the mailbox from the view also ends the speech animation.

### Live versus flowing speech

**Live (default):** particles hold horizontal stations and move vertically to show the latest 480 ms of signed audio peaks. New waveform data appears at the left and advances to the right. Trails are always off so the waveform remains readable. Flash factor controls the audible syllable lighting.

**Flowing:** particles travel across the front of the sphere through three organic waveform ribbons, with roughly 3.2 seconds of visible envelope history. The return path remains at 1% visibility while speaking. `speakingTrailLength` replaces the normal trail setting, then normal trails return after speech ends.

Voice light uses a short rounded attack and release, independent of the longer waveform history. It pulses with speech rather than following a periodic oscillator. Values above 100% flash factor can emit above SDR white, within display headroom.

## Rendering and resource ownership

`Sources/SnowGlobe/ParticleRenderer.swift` and `Shaders/Particles.metal` remain implementation details. Consumers should use `SnowGlobeView`, `SnowGlobeConfiguration`, `SpeechMeter`, and `SpeechEnvelope`.

- Metal compute kernels run a fixed **120 Hz** simulation. Rendering follows the display refresh rate with a bounded catch-up step count.
- The simulation maintains **33,600 particle slots**, a spatial collision grid, and **256 position-history samples per particle** for curved trails. History alone uses about **131 MiB per globe**. The prototype favors quality; reducing visible count currently does not reduce this allocation.
- Disc guidance releases nonlinearly above about 40% effort. At 50%, two opposing, perpendicular currents are established, with additional midpoint energy. Higher effort adds more rotating currents, sparkle, and collisions.
- `rgba16Float`, extended-linear Display P3, and `CAMetalLayer` EDR preserve highlights above SDR white. Headroom follows the current display and can vary with brightness, power, and screen configuration.
- Shader resources are resolved from **`Bundle.module`**, never `Bundle.main`. Xcode compiles processed Metal resources to the package's `default.metallib`. Command-line SwiftPM copies the source; the loader compiles the same shader source at runtime for that build path.
- The shader loader does not fall back to a host application's unrelated Metal library. Keep the package resource bundle with any manually copied build products.
- The SwiftUI bridge retains the renderer through its coordinator and pauses/releases it when dismantled. Hiding a view with opacity alone does not dismantle or pause it.

This is the completed visual prototype, not a performance-tuned low-memory widget. Profile on target devices before displaying many simultaneous globes. The sample's controls allow you to evaluate density, size, trails, and effort at different view sizes.

## Demo controls and command line

The resizable macOS window includes light/dark appearance, simulated connection, Ring/Disc, activity, particle count, size, idle speed, normal and speaking trails, live waveform, speech expression, flash factor, and a text editor with standard Cut/Copy/Paste commands.

The demo synthesizes each sentence with `/usr/bin/say -v "Jamie (Premium)"`, plays clips using `AVAudioPlayer`, and prepares subsequent sentences in the background. Stop cancels playback and outstanding synthesis. A missing voice or failed synthesis is reported in the UI. The package itself has no dependency on Jamie, Siri, `/usr/bin/say`, or Natural Language sentence splitting.

Build from Terminal:

```sh
./scripts/build.sh
open 'build/Build/Products/Release/Snow Globe.app'
```

Optional preview arguments:

```sh
open 'build/Build/Products/Release/Snow Globe.app' --args \
  --preview-activity 1 --particle-limit 10000 --particle-size 1.75
```

| Argument | Effect |
| --- | --- |
| `--preview-activity 0…1` | Initial effort |
| `--particle-limit 10…33600` | Initial full-effort population limit |
| `--particle-size 0.5…20` | Initial size multiplier |
| `--light` | Start in light appearance |
| `--ring` | Start with ring distribution |
| `--disconnected` | Start with particles falling to the bottom |
| `--flowing-waveform` | Start with flowing speech instead of live |
| `--speech-demo` | Speak the default text shortly after launch, if connected |
| `--speech-log PATH` | Write demo playback statistics |
| `--window-info PATH` | Write the demo's window identifier and dimensions |

The legacy `--live-waveform` argument is no longer necessary: live is now the package and demo default. The old app-level `--render-check` route has moved into the test target.

## Tests and validation

Run the package tests independently of the app:

```sh
swift test -c release
```

Or run the checked-in Xcode project's tests, including its compiled Metal bundle:

```sh
./scripts/validate.sh
```

The script builds the demo, runs the Xcode test target, and stores the `.xcresult` under `build/`. GPU tests emit PNG previews and `validation.json`; the test log prints their output directory. For direct SwiftPM runs you can choose a stable location:

```sh
SNOW_GLOBE_VALIDATION_OUTPUT="$PWD/build/validation" swift test -c release
```

Tests cover the shipped defaults and input sanitation, mailbox/session semantics, audio analysis, CPU/GPU buffer layout, finite simulation, sphere confinement, organic wall-following currents, particle admission, count and size extremes, adaptive effort changes, curved trails, sparkle, EDR, live speech details, rapid speech completion, disconnect/settling/reconnect, and small-size bloom. The full Metal regression is a macOS test and requires a GPU; it reports a skip if Metal is unavailable. The API/audio tests also compile for iOS.

`Tests/SnowGlobeTests/Fixtures/SpeechFixture.aiff` supplies reproducible spoken audio. Tests do not need an installed speech voice, network service, microphone, or audible playback. PNGs are SDR previews and clip HDR highlights; raw linear-light peak measurements are recorded separately.

## Layout

```text
Snow Globe/
├── Package.swift                     # Reusable SnowGlobe library product
├── Snow Globe.xcodeproj/             # Demo + tests; local package dependency
├── project.yml                       # Reproducible XcodeGen definition
├── Sources/SnowGlobe/
│   ├── SnowGlobeView.swift            # Public SwiftUI view and platform bridges
│   ├── SnowGlobeConfiguration.swift   # Defaults, ranges, appearance and modes
│   ├── SpeechMeter.swift              # Thread-safe live input
│   ├── SpeechEnvelope.swift           # Optional file audio analyzer
│   ├── ParticleRenderer.swift        # Internal Metal host and simulation
│   ├── MetalLibrary.swift             # Package-owned shader loading
│   └── Shaders/Particles.metal        # Production compute/render kernels
├── Examples/SnowGlobeDemo/            # App window, controls, local TTS playback
├── Tests/SnowGlobeTests/              # API checks and production GPU regression
│   └── Fixtures/                     # Recorded TTS input, test-only resource
└── scripts/                          # Build and validation entry points
```

## Troubleshooting

**Blank globe or initialization error:** use a Metal-capable device and verify the `SnowGlobe` resource bundle is present. The view displays an initialization error and optionally calls `onError` on the main queue. GPU command errors are logged by the renderer.

**No HDR sparkle:** confirm the window is on an EDR-capable display with available headroom. An SDR screenshot cannot reproduce XDR peaks. Small globes deliberately reduce sustained glow.

**Voice light but no detailed live waveform:** publish all 512 signed peak pairs aligned to the playback clock, or switch to `.flowing` for an envelope-only source.

**Particles keep speaking after audio ends:** publish `meter.store(.zero, sessionActive: false)` from completion and cancellation callbacks. Pauses deliberately preserve speech mode while the session remains active.

**Reconnection returns to high effort:** reset the consumer's activity to zero on reconnect if the desired state is idle.

**Project file changes after adding files:** regenerate with `xcodegen generate`. SwiftPM discovers library source files automatically; the XcodeGen spec defines the app and test source folders.
