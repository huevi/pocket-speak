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
    private var port = 0
    private var reading: Task<Void, Never>?
    private var activeRead: UUID?
    private var loginItem: NSMenuItem?
    private var captureInProgress = false

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
        do {
            try registerShortcut()
            try startServer()
            Task {
                do {
                    try await waitForServer()
                    if reading == nil { showReady() }
                } catch {
                    if reading == nil { show(error) }
                }
            }
        } catch {
            show(error)
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
        if let server, server.isRunning { server.terminate() }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func setupMenu() {
        statusItem.button?.title = "Pocket"
        statusItem.button?.toolTip = "Pocket Speak"
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
        add("Accessibility Settings…", #selector(openAccessibility), to: menu)
        loginItem = add("Open at Login", #selector(toggleLogin), to: menu)
        updateLoginMenu()
        menu.addItem(.separator())
        add("Quit Pocket Speak", #selector(quit), to: menu)
        statusItem.menu = menu
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

    private func registerShortcut() throws {
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
        guard register == noErr else { throw SpeechError.hotkey(register) }
        log("Option–Escape registered")
    }

    private func startServer() throws {
        if server?.isRunning == true { return }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "pocket-tts") else {
            throw SpeechError.engine
        }
        port = Int.random(in: 49_152...65_535)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--host", "127.0.0.1", "--port", String(port),
                             "--language", "english", "--default-voice", "alba"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
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
        guard !captureInProgress else { return }
        let start = ContinuousClock.now
        let selectedVoice = voice
        let selectedSpeed = speed
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
                let text = try await selection()
                try Task.checkCancellation()
                log("Captured \(text.utf8.count) bytes in \(start.duration(to: .now))")
                detail.title = "Starting speech…"
                try startServer()
                try await waitForServer()
                try await speak(text, voice: selectedVoice, speed: selectedSpeed, started: start, id: id)
                if activeRead == id { showReady() }
            } catch is CancellationError {
                return
            } catch {
                if activeRead == id {
                    player.stop()
                    audio.stop()
                    show(error)
                }
            }
        }
    }

    private func selection() async throws -> String {
        guard AXIsProcessTrusted() else { throw SpeechError.permission }
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
        var sentence = try await synthesize(sentences[0], voice: voice)
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
            if !isLast { sentence = try await synthesize(sentences[index + 1], voice: voice) }
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

    private func synthesize(_ text: String, voice: String) async throws -> AVAudioPCMBuffer {
        var form = URLComponents()
        var fields = [URLQueryItem(name: "text", value: text)]
        if voice != "alba" { fields.append(URLQueryItem(name: "voice_url", value: voice)) }
        form.queryItems = fields
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
