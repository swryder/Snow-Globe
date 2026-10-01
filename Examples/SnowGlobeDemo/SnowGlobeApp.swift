import SwiftUI
import SnowGlobe

@main
enum SnowGlobeApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = SnowGlobeWindowController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// Own the controls window explicitly; the globe can move into a separate panel.
@MainActor
final class SnowGlobeWindowController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About Snow Globe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Snow Globe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Snow Globe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        // TextEditor participates in AppKit's responder chain. Standard Edit
        // commands route to the focused text view, including in its popover.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let content = NSHostingController(rootView: ContentView())
            // Window sizes are managed explicitly when the globe detaches.
            // Avoid an asynchronous SwiftUI size proposal overriding restoration.
            content.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: content)
            window.title = "Snow Globe"
            window.identifier = NSUserInterfaceItemIdentifier("snow-globe-controls")
            window.delegate = self
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 540, height: 790)
            window.setContentSize(NSSize(width: 1000, height: 928))
            window.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // A borderless globe must never strand the app without its controls.
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var activity: Double = 0
    @State private var connected = true
    @State private var dark = SnowGlobeConfiguration.default.appearance == .dark
    @State private var disc = SnowGlobeConfiguration.default.shape == .disc
    @State private var particleLimit: Double = Double(SnowGlobeConfiguration.default.particleCount)
    @State private var particleSize: Double = Double(SnowGlobeConfiguration.default.particleSize)
    @State private var idleSpeed: Double = Double(SnowGlobeConfiguration.default.idleSpeed)
    @State private var trailLength: Double = Double(SnowGlobeConfiguration.default.trailLength)
    @State private var speakingTrailLength: Double = Double(SnowGlobeConfiguration.default.speakingTrailLength)
    @StateObject private var speech = SpeechController()
    @State private var speechExpression: Double = Double(SnowGlobeConfiguration.default.speechExpression)
    @State private var liveWaveform = SnowGlobeConfiguration.default.speechMode == .live
    @State private var flashFactor: Double = Double(SnowGlobeConfiguration.default.flashFactor)
    @State private var editingSpeech = false
    @State private var floating = false
    @State private var transparency: Double = 0.25
    @State private var glassEffect = Double(SnowGlobeConfiguration.default.glassEffect)
    @State private var motion = GlobeMotion()
    @State private var motionSensitivity = Double(SnowGlobeConfiguration.default.motionSensitivity)
    @StateObject private var desktopGlass = DesktopGlassCapture()
    @State private var contextItems: [SnowGlobeContextItem] = []
    @State private var nextFile = 1

    init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--preview-activity"), args.count > index+1,
           let value = Double(args[index+1]), value.isFinite {
            _activity = State(initialValue: min(1,max(0,value)))
        }
        if let index = args.firstIndex(of: "--particle-limit"), args.count > index+1,
           let value = Double(args[index+1]), value.isFinite {
            _particleLimit = State(initialValue: min(33_600,max(10,value.rounded())))
        }
        if let index = args.firstIndex(of: "--particle-size"), args.count > index+1,
           let value = Double(args[index+1]), value.isFinite {
            _particleSize = State(initialValue: min(20,max(0.5,value)))
        }
        if args.contains("--light") { _dark = State(initialValue: false) }
        if args.contains("--ring") { _disc = State(initialValue: false) }
        if args.contains("--flowing-waveform") { _liveWaveform = State(initialValue: false) }
        _floating = State(initialValue: args.contains("--floating"))
        if let index = args.firstIndex(of: "--glass-effect"), args.count > index+1,
           let value = Double(args[index+1]), value.isFinite {
            _glassEffect = State(initialValue: min(1,max(0,value)))
        }
        if let index = args.firstIndex(of: "--transparency"), args.count > index+1,
           let value = Double(args[index+1]), value.isFinite {
            _transparency = State(initialValue: min(1,max(0,value)))
        }
        _connected = State(initialValue: !args.contains("--disconnected"))
    }

    private var globeConfiguration: SnowGlobeConfiguration {
        SnowGlobeConfiguration(appearance: dark ? .dark : .light,
                               shape: disc ? .disc : .ring,
                               particleCount: Int(particleLimit.rounded()),
                               particleSize: Float(particleSize), idleSpeed: Float(idleSpeed),
                               trailLength: Float(trailLength), speakingTrailLength: Float(speakingTrailLength),
                               speechExpression: Float(speechExpression),
                               speechMode: liveWaveform ? .live : .flowing, flashFactor: Float(flashFactor),
                               transparentBackground: floating,glassEffect: Float(glassEffect),
                               opacity: floating ? Float(1-transparency) : 1,
                               motionSensitivity: Float(motionSensitivity))
    }

    private var foreground: Color { dark ? Color(white: 0.92) : Color(white: 0.16) }
    private var secondary: Color { foreground.opacity(dark ? 0.43 : 0.48) }
    private var stage: String {
        if !connected { return "AI not connected" }
        switch activity {
        case ..<0.08: return "At rest"
        case ..<0.38: return "Gathering energy"
        case ..<0.72: return "In the flow"
        case ..<0.92: return "Deep in thought"
        default: return "Full spectrum"
        }
    }

    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).foregroundStyle(secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Text(readout).monospacedDigit().foregroundStyle(foreground.opacity(0.8))
            }
            .font(.system(size: 11, weight: .medium))
            Slider(value: value, in: range)
                .tint(dark ? Color(red: 0.60, green: 0.77, blue: 0.85)
                           : Color(red: 0.28, green: 0.47, blue: 0.67))
                .accessibilityLabel("Particle \(title.lowercased())")
                .accessibilityValue(readout)
        }
    }

    var body: some View {
        ZStack {
            (dark ? Color(red: 0.021, green: 0.029, blue: 0.049)
                  : Color(red: 0.94, green: 0.945, blue: 0.955)).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SNOW GLOBE")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .tracking(3.2)
                            .foregroundStyle(foreground)
                        Text("A little atmosphere for a thinking machine.")
                            .font(.system(size: 12))
                            .foregroundStyle(secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.65)) { dark.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                                .font(.system(size: 12))
                            Text(dark ? "Dark" : "Light")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(foreground.opacity(0.78))
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(foreground.opacity(0.055), in: Capsule())
                        .overlay(Capsule().strokeBorder(foreground.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Switch between light and dark appearance")
                    .accessibilityLabel("Dark appearance")
                    .accessibilityValue(dark ? "On" : "Off")
                }
                .padding(.horizontal, 36).padding(.top, 33)

                GlobeSurface(globe: SnowGlobeView(activity: Float(activity), isConnected: connected,
                                                   configuration: globeConfiguration, speechMeter: speech.meter,
                                                   glassBackdrop: desktopGlass.backdrop, motion: motion,
                                                   contextItems: contextItems),
                             isFloating: floating,
                             glassEffect: glassEffect,capture: desktopGlass)
                    .frame(maxWidth: .infinity, maxHeight: floating ? 0 : .infinity)
                    .frame(height: floating ? 0 : nil)
                    .accessibilityLabel("Animated particle snow globe")
                    .accessibilityValue(stage)

                VStack(spacing: 15) {
                    HStack {
                        Toggle("Free-floating globe", isOn: $floating)
                            .toggleStyle(.switch).controlSize(.small)
                            .font(.system(size: 12, weight: .medium))
                            .help("Move the globe into a borderless desktop overlay and keep this window for controls.")
                        Spacer()
                    }
                    HStack(alignment: .bottom, spacing: 18) {
                        tuningSlider("Motion sensitivity",value: $motionSensitivity,range: 0...2,
                                     readout: motionSensitivity < 0.005 ? "Off" : "\(Int((motionSensitivity*100).rounded()))%")
                            .help("Drag the globe or its window to stir the particles. Settled snow responds most strongly; AI currents reduce the influence.")
                        Button("Shake globe", systemImage: "hand.draw") { motion.shake() }
                            .controlSize(.small)
                            .disabled(motionSensitivity < 0.005)
                            .padding(.bottom, 2)
                    }
                    tuningSlider("Glass effect",value: $glassEffect,range: 0...1,
                                 readout: glassEffect < 0.005 ? "Off" : "\(Int((glassEffect*100).rounded()))%")
                        .accessibilityLabel("Glass effect")
                        .help("Bend particles, trails, and the desktop through curved glass. Desktop refraction needs Screen Recording access. The strongest lensing is near the edge.")
                    if floating {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Glass transparency")
                                Spacer()
                                Text("\(Int((transparency*100).rounded()))% transparent").monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondary)
                            Slider(value: $transparency, in: 0...1)
                                .accessibilityLabel("Glass transparency")
                                .accessibilityValue("\(Int((transparency*100).rounded())) percent transparent")
                                .help("Adjust the glass tint from solid to clear. Particles and trails stay fully visible, and Glass effect controls refraction independently.")
                            Text("Drag the globe to move it. Turn off Free-floating globe to bring it back.")
                                .font(.system(size: 10)).foregroundStyle(secondary)
                        }
                        if glassEffect > 0.0001 {
                            HStack(spacing: 12) {
                                Text(desktopGlass.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(desktopGlass.needsAction ? foreground.opacity(0.85) : secondary)
                                    .fixedSize(horizontal: false,vertical: true)
                                Spacer(minLength: 0)
                                if desktopGlass.needsAction {
                                    Button(desktopGlass.state == .permissionNeeded ? "Enable desktop refraction" : "Retry") { desktopGlass.enable() }
                                        .controlSize(.small)
                                        .help("Allow Snow Globe to read screen pixels for live refraction. Nothing is recorded or sent anywhere.")
                                }
                            }
                        }
                    }
                    Divider().overlay(foreground.opacity(0.05))
                    HStack {
                        Button {
                            connected.toggle()
                            activity = 0
                            if !connected { speech.stop() }
                        } label: {
                            Label(connected ? "AI connected" : "AI not connected",
                                  systemImage: connected ? "wifi" : "wifi.slash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(connected ? Color.green : secondary)
                        }
                        .buttonStyle(.bordered)
                        .help(connected ? "Simulate disconnecting: particles fall to the bottom." : "Simulate connecting: particles rise into the idle current.")
                        .accessibilityLabel("AI connection")
                        .accessibilityValue(connected ? "Connected" : "Not connected")
                        Spacer()
                        Picker("Flow shape", selection: $disc) {
                            Text("Ring").tag(false)
                            Text("Disc").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 165)
                        .help("Disc fills the center through 40% effort, then gradually releases particles toward the glass")
                    }

                    contextControls

                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 9) {
                            Circle().fill(connected ? Color(red: 0.43, green: 0.78, blue: 0.91) : Color.gray)
                                .frame(width: 5, height: 5)
                                .shadow(color: .cyan.opacity(dark ? 0.6 : 0), radius: 5)
                            Text(stage).font(.system(size: 14, weight: .medium))
                        }
                        Spacer()
                        Text("\(Int(activity * 100))")
                            .font(.system(size: 23, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondary)
                    }
                    .foregroundStyle(foreground.opacity(0.88))

                    Slider(value: $activity, in: 0...1)
                        .disabled(!connected)
                        .tint(dark ? Color(red: 0.60, green: 0.77, blue: 0.85)
                                  : Color(red: 0.28, green: 0.47, blue: 0.57))
                        .accessibilityLabel("AI activity")
                        .accessibilityValue("\(Int(activity * 100)) percent")

                    HStack {
                        Text("IDLE")
                        Spacer()
                        Text("ACTIVITY")
                        Spacer()
                        Text("MAX EFFORT")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(secondary)

                    HStack(spacing: 20) {
                        tuningSlider("Particles", value: Binding(
                            get: { log10(particleLimit) },
                            set: { particleLimit = min(33_600,max(10,pow(10,$0).rounded())) }
                        ), range: 1...log10(33_600),
                                     readout: Int(particleLimit.rounded()).formatted())
                            .help("Particle limit at full effort. Lower effort admits fewer particles. The slider gives extra precision to small counts.")
                            .disabled(!connected)
                        tuningSlider("Size", value: $particleSize, range: 0.5...20,
                                     readout: String(format: "%.2f×", particleSize))
                        tuningSlider("Idle speed", value: $idleSpeed, range: 0.5...Double(SnowGlobeConfiguration.idleSpeedRange.upperBound),
                                     readout: String(format: "%.2f×", idleSpeed))
                            .help("Minimum movement speed. 1× is the original idle pace; blends smoothly into activity-driven motion.")
                    }
                    .padding(.top, 3)

                    HStack(spacing: 20) {
                        tuningSlider("Trail length", value: $trailLength, range: 0...1,
                                     readout: trailLength < 0.005 ? "Off" : "\(Int((trailLength * 100).rounded()))%")
                            .help("Normal trail length, restored smoothly after speech finishes.")
                        tuningSlider("While speaking", value: $speakingTrailLength, range: 0...1,
                                     readout: liveWaveform || speakingTrailLength < 0.005 ? "Off" : "\(Int((speakingTrailLength * 100).rounded()))%")
                            .disabled(liveWaveform)
                            .accessibilityLabel("While speaking trail length")
                            .help("Trail length for flowing speech. Live waveform always has trails off to keep the audio shape clear.")
                    }

                    Divider().overlay(foreground.opacity(0.05))
                    HStack {
                        Toggle("Live waveform", isOn: $liveWaveform)
                            .toggleStyle(.switch).controlSize(.small)
                            .font(.system(size: 11, weight: .medium))
                            .fixedSize()
                            .help("Hold particles horizontally and move them vertically with detailed audio peaks from the latest half-second of speech. Live trails are off. Turn off to restore the circulating waveform.")
                        Spacer()
                        Text(liveWaveform ? "Vertical · current speech" : "Flowing · speech history")
                            .font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Button {
                                    if speech.isActive { speech.stop() } else { speech.speak() }
                                } label: {
                                    Label(speech.isActive ? "Stop" : "Speak", systemImage: speech.isActive ? "stop.fill" : "speaker.wave.2.fill")
                                }
                                .disabled(!connected)
                                .buttonStyle(.bordered)
                                Button { editingSpeech = true } label: { Image(systemName: "text.bubble") }
                                    .buttonStyle(.bordered)
                                    .help("Edit the speech test text")
                                    .popover(isPresented: $editingSpeech) {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text("Give the globe a voice").font(.headline)
                                            TextEditor(text: $speech.text)
                                                .font(.body).frame(width: 420, height: 145)
                                            HStack {
                                                Button("Sample text") { speech.text = SpeechController.sampleText }
                                                Spacer()
                                                Button("Speak") { editingSpeech = false; speech.speak() }
                                                    .disabled(!connected)
                                                    .buttonStyle(.borderedProminent)
                                            }
                                        }.padding(20)
                                    }
                            }
                            Text(speech.status).font(.system(size: 10)).foregroundStyle(secondary)
                        }
                        tuningSlider("Speech expression", value: $speechExpression, range: 0...2,
                                     readout: "\(Int((speechExpression*100).rounded()))%")
                            .help("How strongly speech stirs and illuminates the particles. Zero keeps the voice audible with no speech animation.")
                        tuningSlider("Flash factor", value: $flashFactor, range: 0...Double(SnowGlobeConfiguration.flashFactorRange.upperBound),
                                     readout: "\(Int((flashFactor*100).rounded()))%")
                            .help("Speech light intensity. Above 100% overdrives highlights into the available XDR headroom. Zero removes the extra voice flash.")
                    }
                    if let error = speech.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 27).padding(.vertical, 24)
                .background(foreground.opacity(dark ? 0.027 : 0.035), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(foreground.opacity(0.07)))
                .frame(maxWidth: 560)
                .padding(.horizontal, 36)
                .padding(.top, floating ? 24 : 0)
                .padding(.bottom, 30)
            }
        }
        .frame(minWidth: 540, minHeight: floating ? 740 : 790)
        .preferredColorScheme(dark ? .dark : .light)
        .onChange(of: dark) { _, value in
            NSApp.windows.first(where: { $0.identifier?.rawValue == "snow-globe-controls" })?.appearance = NSAppearance(named: value ? .darkAqua : .aqua)
        }
        .onChange(of: desktopGlass.state) { _, _ in writeWindowInfo() }
        .onAppear {
            // Optional local QA aid: identifies only this app's own window.
            let args = CommandLine.arguments
            if args.contains("--speech-demo") && connected {
                DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { if connected { speech.speak() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { writeWindowInfo() }
        }
    }

    private var pendingFiles: Int { contextItems.filter { $0.state == .pending }.count }

    /// Simulates files dropped into the chat, then sent with the user's turn.
    private var contextControls: some View {
        HStack(spacing: 8) {
            Button("Attach file", systemImage: "doc.badge.plus") {
                // The host drops committed items whenever it likes; the globe keeps animating.
                contextItems.removeAll { $0.state == .committed }
                contextItems.append(SnowGlobeContextItem(id: "file-\(nextFile)"))
                nextFile += 1
            }
            .help("Add a file the agent can see. Up to six appear as large particles.")
            Button("Remove", systemImage: "minus.circle") {
                if let index = contextItems.lastIndex(where: { $0.state == .pending }) { contextItems.remove(at: index) }
            }
            .disabled(pendingFiles == 0)
            .help("Delete the most recent attached file. Its particle fades out.")
            Button("Send", systemImage: "paperplane") {
                for index in contextItems.indices { contextItems[index].state = .committed }
            }
            .disabled(pendingFiles == 0)
            .help("Complete the turn. Each file's particle breaks up into the stream.")
            Spacer()
            Text(pendingFiles == 1 ? "1 file attached" : "\(pendingFiles) files attached")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    /// Opt-in local QA metadata; never writes captured screen pixels.
    private func writeWindowInfo() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--window-info"), args.count > index+1,
              let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "snow-globe-controls" }) else { return }
        var info: [String: Any] = ["windowNumber": window.windowNumber,
                                  "width": window.frame.width, "height": window.frame.height,
                                  "minWidth": window.contentMinSize.width, "minHeight": window.contentMinSize.height,
                                  "desktopRefraction": desktopGlass.message,
                                  "screenAccess": CGPreflightScreenCaptureAccess()]
        if let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "snow-globe-floating" }) {
            info["floatingWindowNumber"] = panel.windowNumber
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: args[index+1]),options: .atomic)
        }
    }
}
