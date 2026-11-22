import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import NaturalLanguage
import ServiceManagement

enum SpeechError: LocalizedError {
    case permission, selection, engine, audio, hotkey(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permission: return "Enable Pocket Speak in Accessibility settings."
        case .selection: return "Select some text to read."
        case .engine: return "The Pocket TTS engine did not respond."
        case .audio: return "Pocket TTS did not return playable audio."
        case .hotkey(let status): return "Option–Escape is unavailable (\(status))."
        }
    }
}

@MainActor final class PocketSpeak: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let detail = NSMenuItem(title: "Starting Pocket TTS…", action: nil, keyEquivalent: "")
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let voices = ["alba", "anna", "marius", "george", "vera"]
    private let speeds: [(String, Float)] = [("0.8×", 0.8), ("1×", 1), ("1.25×", 1.25), ("1.5×", 1.5)]
    private let voiceMenu = NSMenu(title: "Voice")
    private let speedMenu = NSMenu(title: "Speed")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 45
        return URLSession(configuration: config)
    }()
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var server: Process?
    private var serverVoice: String?
    private var port = 0
    private var reading: Task<Void, Never>? {
        didSet { updateStatusIcon() }
    }
    private var activeRead: UUID?
    private var loginItem: NSMenuItem?
    private var captureInProgress = false

    private enum SetupStep {
        case download, downloading(Int64), downloadFailed(String), starting, engineFailed(String)
        case preview, permission, shortcut(String?), complete
    }

    private var assets = ModelAssets()
    private var setupWindow: SetupWindow?
    private var setupStep: SetupStep = .download {
        didSet { updateSetupWindow() }
    }
    private var setupTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var engineReady = false
    private var previewPlayed = false
    private var setupFinished: Bool {
        UserDefaults.standard.bool(forKey: "finishedSetup")
    }

    private var voice: String {
        let saved = UserDefaults.standard.string(forKey: "voice") ?? "alba"
        return voices.contains(saved) ? saved : "alba"
    }

    private var speed: Float {
        let saved = UserDefaults.standard.float(forKey: "speed")
        return speeds.first { $0.1 == saved }?.1 ?? 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        audio.attach(player)
        audio.attach(timePitch)
        audio.connect(player, to: timePitch, format: format)
        audio.connect(timePitch, to: audio.mainMixerNode, format: format)
        setupMenu()
        #if SETUP_SMOKE_TEST
        if let command = CommandLine.arguments.dropFirst().first {
            runSetupSmoke(command)
            return
        }
        #endif
        if assets.isInstalled {
            if setupFinished && AXIsProcessTrusted() { enableShortcut() }
            else { openSetup() }
            prepareEngine()
        } else {
            detail.title = "Set up the voice to begin"
            openSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        setupTask?.cancel()
        permissionTask?.cancel()
        stop()
        if let server, server.isRunning { server.terminate() }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func setupMenu() {
        updateStatusIcon()
        let menu = NSMenu()
        menu.addItem(detail)
        menu.addItem(.separator())
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceItem.submenu = voiceMenu
        for name in voices {
            add(name.capitalized, #selector(setVoice(_:)), to: voiceMenu).representedObject = name
        }
        menu.addItem(voiceItem)

        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        for (label, rate) in speeds {
            add(label, #selector(setSpeed(_:)), to: speedMenu).representedObject = NSNumber(value: rate)
        }
        menu.addItem(speedItem)
        updateChoices()
        menu.addItem(.separator())
        add("Stop Speaking", #selector(stop), to: menu)
        add("Setup…", #selector(openSetup), to: menu)
        add("Accessibility Settings…", #selector(openAccessibility), to: menu)
        loginItem = add("Open at Login", #selector(toggleLogin), to: menu)
        updateLoginMenu()
        menu.addItem(.separator())
        add("Quit Pocket Speak", #selector(quit), to: menu)
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let isReading = reading != nil
        let description = isReading ? "Pocket Speak, reading" : "Pocket Speak"
        let symbol = isReading ? "text.bubble.fill" : "text.bubble"
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.toolTip = isReading ? "Pocket Speak · Option–Escape to stop" : "Pocket Speak"
        button.setAccessibilityLabel(description)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func setVoice(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, voices.contains(name) else { return }
        UserDefaults.standard.set(name, forKey: "voice")
        updateChoices()
        if reading == nil { showReady() }
    }

    @objc private func setSpeed(_ item: NSMenuItem) {
        guard let rate = (item.representedObject as? NSNumber)?.floatValue,
              speeds.contains(where: { $0.1 == rate }) else { return }
        UserDefaults.standard.set(rate, forKey: "speed")
        updateChoices()
        if reading == nil { showReady() }
    }

    private func updateChoices() {
        for item in voiceMenu.items {
            item.state = (item.representedObject as? String) == voice ? .on : .off
        }
        for item in speedMenu.items {
            item.state = (item.representedObject as? NSNumber)?.floatValue == speed ? .on : .off
        }
    }

    private func showReady() {
        let speedLabel = speeds.first { $0.1 == speed }?.0 ?? "1×"
        detail.title = "Pocket TTS · \(voice.capitalized) · \(speedLabel) · Ready"
    }

    @objc private func openSetup() {
        if setupWindow == nil { setupWindow = SetupWindow() }
        updateSetupWindow()
        setupWindow?.focus()
    }

    private func updateSetupWindow() {
        guard let window = setupWindow else { return }
        let downloadSize = ByteCountFormatter.string(fromByteCount: ModelAssets.totalSize, countStyle: .file)
        switch setupStep {
        case .download:
            window.update("Download English voices",
                          "The full Pocket TTS model and five voice presets need a one-time \(downloadSize) download. After setup, speech runs offline on this Mac.",
                          action: ("Download", { [weak self] in _ = self?.downloadAssets() }))
        case let .downloading(bytes):
            let fraction = Double(bytes) / Double(ModelAssets.totalSize)
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            window.update("Downloading English voices", "\(size) of \(downloadSize). You can leave this window open or come back later.",
                          fraction: fraction, alternate: ("Cancel", { [weak self] in _ = self?.setupTask?.cancel() }))
        case let .downloadFailed(message):
            window.update("Download paused", message,
                          action: ("Retry", { [weak self] in _ = self?.downloadAssets() }))
        case .starting:
            window.update("Loading Pocket TTS", "Pocket Speak is loading the voices on this Mac.")
        case let .engineFailed(message):
            window.update("Couldn’t load Pocket TTS", message,
                          action: ("Retry", { [weak self] in _ = self?.prepareEngine() }),
                          alternate: ("Verify Downloads", { [weak self] in _ = self?.downloadAssets() }))
        case .preview:
            window.update("Hear a sample", "Play a short sentence with Alba to check your audio output.",
                          action: ("Play Sample", { [weak self] in _ = self?.playSetupSample() }),
                          alternate: previewPlayed ? ("Continue", { [weak self] in _ = self?.enableShortcut() }) : nil)
        case .permission:
            window.update("Allow selected-text access",
                          "macOS Accessibility lets Pocket Speak read highlighted text from other apps. Enable Pocket Speak in Privacy & Security → Accessibility.",
                          action: ("Open Accessibility Settings", { [weak self] in _ = self?.openAccessibility() }))
        case let .shortcut(error):
            let text = error ?? "Highlight the sample below and press Option–Escape. If Apple’s voice speaks, disable or reassign Speak Selection in Accessibility → Read & Speak."
            window.update("Try Option–Escape", text, showSample: error == nil,
                          action: error == nil ? nil : ("Retry Shortcut", { [weak self] in _ = self?.enableShortcut() }),
                          alternate: ("Open Read & Speak", {
                              _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                          }))
        case .complete:
            window.update("Pocket Speak is ready", "Highlight text in an app and press Option–Escape to read it aloud. Press it again to stop.",
                          action: ("Done", { [weak self] in _ = self?.setupWindow?.close() }))
        }
    }

    private func downloadAssets() {
        guard setupTask == nil else { return }
        setupStep = .downloading(0)
        detail.title = "Downloading English voices…"
        setupTask = Task {
            do {
                try await assets.install { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, case let .downloading(previous) = self.setupStep, bytes > previous else { return }
                        self.setupStep = .downloading(bytes)
                    }
                }
                try Task.checkCancellation()
                setupTask = nil
                prepareEngine()
            } catch {
                setupTask = nil
                setupStep = .downloadFailed(Task.isCancelled
                    ? "The download was canceled. Retry to reuse any completed files."
                    : error.localizedDescription)
                detail.title = "Voice setup needs attention"
            }
        }
    }

    private func prepareEngine() {
        guard setupTask == nil else { return }
        setupStep = .starting
        detail.title = "Loading Pocket TTS…"
        setupTask = Task {
            defer { setupTask = nil }
            do {
                try startServer(voice: voice)
                try await waitForServer()
                engineReady = true
                showReady()
                if setupFinished { enableShortcut() }
                else { setupStep = .preview }
            } catch is CancellationError {
                return
            } catch {
                if let server, server.isRunning { server.terminate() }
                engineReady = false
                setupStep = .engineFailed(error.localizedDescription)
                detail.title = "Voice setup needs attention"
                openSetup()
            }
        }
    }

    private func enableShortcut() {
        guard AXIsProcessTrusted() else {
            setupStep = .permission
            if permissionTask == nil {
                permissionTask = Task {
                    while !AXIsProcessTrusted() {
                        try? await Task.sleep(for: .milliseconds(500))
                        if Task.isCancelled { return }
                    }
                    permissionTask = nil
                    enableShortcut()
                }
            }
            return
        }
        do {
            try registerShortcut()
            setupStep = setupFinished ? .complete : .shortcut(nil)
        } catch {
            setupStep = .shortcut(error.localizedDescription)
            openSetup()
        }
    }

    private func playSetupSample() {
        guard engineReady, reading == nil, let sample = setupWindow?.sampleText else { return }
        startReading(sample: sample)
    }

    private func registerShortcut() throws {
        if hotkey != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<PocketSpeak>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in app.toggleReading() }
            return noErr
        }, 1, &spec, context, &handler)
        guard install == noErr else { throw SpeechError.hotkey(install) }
        let id = EventHotKeyID(signature: 0x50545350, id: 1)
        let register = RegisterEventHotKey(
            UInt32(kVK_Escape), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotkey
        )
        guard register == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw SpeechError.hotkey(register)
        }
        log("Option–Escape registered")
    }

    private func startServer(voice: String) throws {
        if let server, server.isRunning {
            if serverVoice == voice { return }
            server.terminate()
        }
        guard assets.isInstalled,
              let executable = Bundle.main.url(forAuxiliaryExecutable: "pocket-tts"),
              let config = Bundle.main.url(forResource: "english", withExtension: "yaml") else {
            throw SpeechError.engine
        }
        port = Int.random(in: 49_152...65_535)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = assets.directory
        process.arguments = ["serve", "--host", "127.0.0.1", "--port", String(port),
                             "--config", config.path, "--default-voice", assets.location("\(voice).safetensors").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        serverVoice = voice
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    private func waitForServer() async throws {
        var request = URLRequest(url: endpoint("health"), timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard server?.isRunning == true else { throw SpeechError.engine }
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SpeechError.engine
    }

    private func toggleReading() {
        if reading != nil {
            stop()
            return
        }
        guard engineReady else {
            openSetup()
            return
        }
        guard !captureInProgress else { return }
        startReading()
    }

    private func startReading(sample: String? = nil) {
        let start = ContinuousClock.now
        let selectedVoice = sample == nil ? voice : "alba"
        let selectedSpeed: Float = sample == nil ? speed : 1
        let id = UUID()
        activeRead = id
        reading = Task {
            defer {
                if activeRead == id {
                    activeRead = nil
                    reading = nil
                }
            }
            do {
                let text: String
                if let sample { text = sample }
                else { text = try await selection() }
                try Task.checkCancellation()
                log("Captured \(text.utf8.count) bytes in \(start.duration(to: .now))")
                detail.title = "Starting speech…"
                try startServer(voice: selectedVoice)
                try await waitForServer()
                try await speak(text, voice: selectedVoice, speed: selectedSpeed, started: start, id: id)
                if activeRead == id {
                    showReady()
                    if sample != nil {
                        previewPlayed = true
                        updateSetupWindow()
                    } else if !setupFinished {
                        UserDefaults.standard.set(true, forKey: "finishedSetup")
                        setupStep = .complete
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if activeRead == id {
                    player.stop()
                    audio.stop()
                    show(error)
                    if sample != nil {
                        setupWindow?.update("Couldn’t play the sample", error.localizedDescription,
                                            action: ("Retry", { [weak self] in _ = self?.playSetupSample() }))
                    }
                }
            }
        }
    }

    private func selection() async throws -> String {
        guard AXIsProcessTrusted() else { throw SpeechError.permission }
        if let sample = setupWindow?.selectedSample { return sample }
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &value)
            if value as? String == (kAXSecureTextFieldSubrole as String) { throw SpeechError.selection }
            AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value)
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        captureInProgress = true
        defer { captureInProgress = false }
        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        for _ in 0..<15 {
            await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { wait.resume() }
            }
            let copied = board.changeCount
            guard copied != before else { continue }
            let text = board.string(forType: .string)
            if board.changeCount == copied {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            break
        }
        throw SpeechError.selection
    }

    private func speak(
        _ text: String, voice: String, speed: Float,
        started: ContinuousClock.Instant, id: UUID
    ) async throws {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if sentences.isEmpty { sentences = [text] }

        // Queue complete sentences so generation or network jitter cannot cut into a word.
        var sentence = try await synthesize(sentences[0])
        try Task.checkCancellation()
        audio.reset()
        timePitch.rate = speed
        timePitch.bypass = speed == 1
        try audio.start()
        let preroll = try buffer(Array(repeating: 0, count: 8_640)) // 180 ms for USB output.
        enqueue(preroll)

        var finished = false
        for index in sentences.indices {
            try Task.checkCancellation()
            let isLast = index == sentences.count - 1
            if isLast {
                player.scheduleBuffer(sentence, completionCallbackType: .dataPlayedBack) { _ in
                    Task { @MainActor in finished = true }
                }
            } else {
                enqueue(sentence)
            }
            if index == 0 {
                player.play()
                detail.title = "Speaking · ⌥ Esc to stop"
                log("Playback queued after \(started.duration(to: .now)) with \(voice.capitalized) at \(speed)× (\(sentence.frameLength) frames)")
            }
            if !isLast { sentence = try await synthesize(sentences[index + 1]) }
        }
        while !finished {
            try await Task.sleep(for: .milliseconds(30))
        }
        if activeRead == id {
            player.stop()
            audio.stop()
            log("Playback completed")
        }
    }

    private func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "text", value: text)]
        var request = URLRequest(url: endpoint("tts"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (wav, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpeechError.engine }
        // Pocket TTS returns mono 24 kHz PCM16 with a fixed 44-byte header. For HTTP,
        // it advertises an open-ended data size, so use the actual received bytes.
        let encoding: [UInt8] = [1, 0, 1, 0]
        let sampleRate: [UInt8] = [192, 93, 0, 0]
        let bitDepth: [UInt8] = [16, 0]
        guard wav.count > 44,
              String(bytes: wav[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: wav[36..<40], encoding: .ascii) == "data",
              wav[20..<24].elementsEqual(encoding),
              wav[24..<28].elementsEqual(sampleRate),
              wav[34..<36].elementsEqual(bitDepth) else { throw SpeechError.audio }
        return try buffer(Array(wav.dropFirst(44)))
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func buffer(_ pcm: [UInt8]) throws -> AVAudioPCMBuffer {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw SpeechError.audio }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let value = UInt16(pcm[2 * i]) | UInt16(pcm[2 * i + 1]) << 8
            samples[i] = Float(Int16(bitPattern: value)) / 32768
        }
        return buffer
    }

    @objc private func stop() {
        activeRead = nil
        reading?.cancel()
        reading = nil
        player.stop()
        if audio.isRunning { audio.stop() }
        showReady()
    }

    @objc private func openAccessibility() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
            updateLoginMenu()
        } catch { show(error) }
    }

    private func updateLoginMenu() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func show(_ error: Error) {
        detail.title = error.localizedDescription
        log("Error: \(error.localizedDescription)")
        NSSound.beep()
    }

    #if SETUP_SMOKE_TEST
    private func runSetupSmoke(_ command: String) {
        Task {
            do {
                assets = try smokeAssets()
                if command == "download" { try await checkDownload(assets) }
                try checkInstalled(assets)
                for name in voices {
                    try startServer(voice: name)
                    try await waitForServer()
                    let frames = try await synthesize("Pocket Speak runs locally.").frameLength
                    guard frames > 4_800 else { throw SpeechError.audio }
                    print("Verified \(name): \(frames) frames")
                }
                if command == "offline" {
                    setupWindow = SetupWindow()
                    setupStep = .preview
                    engineReady = true
                    playSetupSample()
                    await reading?.value
                    guard previewPlayed else { throw SpeechError.audio }
                    print("Played the onboarding sample through the app’s audio pipeline.")
                }
                if let server, server.isRunning { server.terminate() }
                exit(EXIT_SUCCESS)
            } catch {
                if let server, server.isRunning { server.terminate() }
                FileHandle.standardError.write(Data("Setup check failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
    #endif

    private func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pocket Speak.log")
        let line = Data("\(ISO8601DateFormatter().string(from: .now)) \(message)\n".utf8)
        if let file = try? FileHandle(forWritingTo: url) {
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: line)
            try? file.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PocketSpeak()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
