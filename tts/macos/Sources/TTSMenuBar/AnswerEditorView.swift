import AppKit
import SwiftUI

struct AnswerEditorContext: Identifiable {
    enum Kind {
        case freeform
        case suggestion(String)
    }

    let questionID: String
    let kind: Kind
    let existingTitle: String?
    let existingDescription: String
    let existingAttachments: [URL]

    var id: String {
        switch kind {
        case .freeform: "\(questionID)::freeform"
        case let .suggestion(id): "\(questionID)::\(id)"
        }
    }

    var isSuggestion: Bool {
        if case .suggestion = kind { return true }
        return false
    }
}

private struct ImmediateClickTarget: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context _: Context) -> ImmediateClickNSView {
        ImmediateClickNSView(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: ImmediateClickNSView, context _: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class ImmediateClickNSView: NSView {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onSingleClick()
        } else if event.clickCount == 2 {
            onDoubleClick()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class AnswerEditorPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var parentWindow: NSWindow?

    func present(
        context: AnswerEditorContext,
        onSave: @escaping (String?, String, [URL]) -> Void
    ) {
        cancel()
        let parent = NSApp.keyWindow
        let editor = AnswerEditorView(
            context: context,
            onCancel: { [weak self] in self?.cancel() },
            onDone: { [weak self] title, description, attachments in
                onSave(title, description, attachments)
                self?.cancel()
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = context.isSuggestion ? "Edit suggestion" : "Write your answer"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: editor)
        panel.minSize = NSSize(width: 520, height: 360)

        let controller = NSWindowController(window: panel)
        windowController = controller
        parentWindow = parent
        if let parent {
            let screenFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
            let proposed = NSPoint(
                x: min(parent.frame.maxX + 16, screenFrame.maxX - panel.frame.width),
                y: min(parent.frame.maxY - panel.frame.height, screenFrame.maxY - panel.frame.height)
            )
            panel.setFrameOrigin(NSPoint(
                x: max(screenFrame.minX, proposed.x),
                y: max(screenFrame.minY, proposed.y)
            ))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        controller.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        guard let panel = windowController?.window else { return }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        windowController = nil
        parentWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        parentWindow?.removeChildWindow(panel)
        windowController = nil
        parentWindow = nil
    }
}

private struct AnswerEditorView: View {
    private enum Field: Hashable {
        case title
        case body
    }

    let context: AnswerEditorContext
    let onCancel: () -> Void
    let onDone: (String?, String, [URL]) -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var attachments: [URL]
    @State private var isDropTarget = false
    @FocusState private var focusedField: Field?

    init(
        context: AnswerEditorContext,
        onCancel: @escaping () -> Void,
        onDone: @escaping (String?, String, [URL]) -> Void
    ) {
        self.context = context
        self.onCancel = onCancel
        self.onDone = onDone
        _title = State(initialValue: context.existingTitle ?? "")
        _bodyText = State(initialValue: context.existingDescription)
        _attachments = State(initialValue: context.existingAttachments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    if context.isSuggestion {
                        TextField("Suggestion title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold))
                            .focused($focusedField, equals: .title)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                        Divider().padding(.horizontal, 20)
                    }

                    TextEditor(text: $bodyText)
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                if isDropTarget {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isDropTarget
                    ? Color.accentColor.opacity(0.08)
                    : Color.clear
            )
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                addFiles(files)
                return !files.isEmpty
            } isTargeted: { isDropTarget = $0 }

            Divider()

            HStack(spacing: 8) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    addFiles(pickFiles())
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .accessibilityLabel("Attach files")

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(attachments, id: \.standardizedFileURL.path) { url in
                                HStack(spacing: 4) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Button {
                                        attachments.removeAll {
                                            $0.standardizedFileURL.path == url.standardizedFileURL.path
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                                }
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: 280)
                }
                Spacer()
                Button("Done") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDone(
                        context.isSuggestion ? trimmedTitle : nil,
                        bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(context.isSuggestion && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 680, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = context.isSuggestion ? .title : .body }
    }

    private func addFiles(_ urls: [URL]) {
        var paths = Set(attachments.map(\.standardizedFileURL.path))
        attachments.append(contentsOf: urls.filter { paths.insert($0.standardizedFileURL.path).inserted })
    }

    private func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach files to your answer"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

extension String {
    var nonemptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
