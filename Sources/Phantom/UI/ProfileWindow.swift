import AppKit
import UniformTypeIdentifiers

// Edits the interview profile: resume file, job description and answer instructions.
final class ProfileWindow: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onSave: (() -> Void)?

    private let resume = ProfileWindow.makeEditor(height: 150, placeholder: "Choose your resume file above, or paste its text here.")
    private let job = ProfileWindow.makeEditor(height: 130, placeholder: "Paste the job description here.")
    private let instructions = ProfileWindow.makeEditor(height: 190, placeholder: "How Phantom should act and format its answers.")
    private let resumeStatus = NSTextField(labelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let enabledBox = NSButton(checkboxWithTitle: "Use this profile in chat", target: nil, action: nil)
    private var resumeName = ""

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Interview profile"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.sharingType = .none   // hidden from screen sharing, like the chat
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 520, height: 640)
        window.delegate = self
        buildLayout()
        load(InterviewProfile.current)
        window.center()
    }

    func show() {
        load(InterviewProfile.current)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private static func makeEditor(height: CGFloat, placeholder: String) -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.setValue(NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 12)]),
            forKey: "placeholderAttributedString")
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return (scroll, tv)
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.boldSystemFont(ofSize: 13)
        return l
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func buildLayout() {
        let intro = NSTextField(wrappingLabelWithString:
            "Phantom sends this with every message so answers fit you and the job. It is saved only on this Mac and sent only to your AI provider.")
        intro.textColor = .secondaryLabelColor
        intro.font = NSFont.systemFont(ofSize: 11)

        resumeStatus.textColor = .secondaryLabelColor
        resumeStatus.font = NSFont.systemFont(ofSize: 11)
        resumeStatus.lineBreakMode = .byTruncatingMiddle
        resumeStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.textColor = .secondaryLabelColor
        footer.font = NSFont.systemFont(ofSize: 11)

        let resumeRow = row([heading("Resume"), button("Choose PDF or Word file…", #selector(chooseResume)),
                             button("Clear", #selector(clearResume)), resumeStatus])
        let jobRow = row([heading("Job description"), button("Clear", #selector(clearJob))])
        let instrRow = row([heading("How Phantom should answer"), button("Use recommended", #selector(useRecommended))])

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveProfile))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command   // Return stays a new line in the boxes
        save.bezelColor = .controlAccentColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = row([enabledBox, spacer, cancel, save])

        let stack = NSStackView(views: [intro, resumeRow, resume.scroll, jobRow, job.scroll,
                                        instrRow, instructions.scroll, footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: intro)
        stack.setCustomSpacing(14, after: resume.scroll)
        stack.setCustomSpacing(14, after: job.scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSView()
        cv.addSubview(stack)
        window.contentView = cv
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
        ])
        for v in [intro, resume.scroll, job.scroll, instructions.scroll, footer, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Long instructions get the extra height when the window grows.
        instructions.scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        for tv in [resume.text, job.text, instructions.text] {
            NotificationCenter.default.addObserver(self, selector: #selector(textChanged),
                                                   name: NSText.didChangeNotification, object: tv)
        }
    }

    // MARK: Data

    private func load(_ p: InterviewProfile) {
        resumeName = p.resumeName
        resume.text.string = p.resumeText
        job.text.string = p.jobDescription
        instructions.text.string = p.instructions
        enabledBox.state = p.enabled ? .on : .off
        updateStatus()
    }

    @objc private func textChanged() { updateStatus() }

    private func updateStatus() {
        let r = resume.text.string.trimmed, j = job.text.string.trimmed
        if r.isEmpty {
            resumeStatus.stringValue = "No resume"
        } else {
            let name = resumeName.isEmpty ? "Pasted text" : resumeName
            resumeStatus.stringValue = "\(name) · \(r.count.formatted()) characters"
        }
        var notes: [String] = []
        let total = min(r.count, InterviewProfile.resumeLimit) + min(j.count, InterviewProfile.jobLimit)
            + instructions.text.string.trimmed.count
        notes.append("Sent with each message: about \((total / 4).formatted()) tokens.")
        if r.count > InterviewProfile.resumeLimit {
            notes.append("Resume is long; only the first \(InterviewProfile.resumeLimit.formatted()) characters are sent.")
        }
        if j.count > InterviewProfile.jobLimit {
            notes.append("Job description is long; only the first \(InterviewProfile.jobLimit.formatted()) characters are sent.")
        }
        footer.stringValue = notes.joined(separator: " ")
    }

    @objc private func chooseResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ResumeReader.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose your resume (PDF or Word)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard let text = ResumeReader.text(from: url) else {
                let alert = NSAlert()
                alert.messageText = "No text found in \(url.lastPathComponent)"
                alert.informativeText = "It may be a scanned image. Open the file, copy its text, and paste it into the Resume box."
                alert.beginSheetModal(for: self.window)
                return
            }
            self.resumeName = url.lastPathComponent
            self.resume.text.string = text
            self.updateStatus()
        }
    }

    @objc private func clearResume() { resumeName = ""; resume.text.string = ""; updateStatus() }
    @objc private func clearJob() { job.text.string = ""; updateStatus() }
    @objc private func useRecommended() {
        instructions.text.string = InterviewProfile.recommendedInstructions
        updateStatus()
    }

    @objc private func cancel() { window.orderOut(nil) }

    @objc private func saveProfile() {
        var p = InterviewProfile()
        p.enabled = enabledBox.state == .on
        p.resumeName = resume.text.string.trimmed.isEmpty ? "" : resumeName
        p.resumeText = resume.text.string.trimmed
        p.jobDescription = job.text.string.trimmed
        p.instructions = instructions.text.string.trimmed
        InterviewProfile.current = p
        window.orderOut(nil)
        onSave?()
    }
}
