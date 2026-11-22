import AppKit

@MainActor final class SetupWindow: NSWindowController {
    private let heading = NSTextField(labelWithString: "")
    private let descriptionField = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let sample = NSTextView()
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Pocket Speak Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        descriptionField.font = .systemFont(ofSize: 14)
        sample.string = "Pocket Speak reads this text aloud on your Mac."
        sample.isEditable = false
        sample.isSelectable = true
        sample.font = .systemFont(ofSize: 14, weight: .medium)
        sample.textContainerInset = NSSize(width: 4, height: 7)
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.style = .bar
        primary.target = self
        primary.action = #selector(runPrimary)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        secondary.target = self
        secondary.action = #selector(runSecondary)
        secondary.bezelStyle = .rounded

        let buttons = NSStackView(views: [primary, secondary])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, descriptionField, progress, sample, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 25),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -25),
            descriptionField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sample.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sample.heightAnchor.constraint(equalToConstant: 32),
        ])
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    var sampleText: String { sample.string }

    var selectedSample: String? {
        guard window?.isKeyWindow == true, !sample.isHidden,
              let range = Range(sample.selectedRange(), in: sample.string), !range.isEmpty else { return nil }
        return String(sample.string[range])
    }

    func focus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ title: String, _ message: String, fraction: Double? = nil, showSample: Bool = false,
                action: (String, () -> Void)? = nil, alternate: (String, () -> Void)? = nil) {
        heading.stringValue = title
        descriptionField.stringValue = message
        progress.isHidden = fraction == nil
        progress.doubleValue = fraction ?? 0
        sample.isHidden = !showSample
        primary.isHidden = action == nil
        primary.title = action?.0 ?? ""
        primaryAction = action?.1
        secondary.isHidden = alternate == nil
        secondary.title = alternate?.0 ?? ""
        secondaryAction = alternate?.1
    }

    @objc private func runPrimary() { primaryAction?() }
    @objc private func runSecondary() { secondaryAction?() }
}
