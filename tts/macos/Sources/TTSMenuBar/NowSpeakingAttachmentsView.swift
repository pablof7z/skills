import AppKit
import SwiftUI

extension NowSpeakingHUDView {
    func summary(item: TTSItem, accent: Color) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: statusSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(
                    width: 40,
                    height: 40
                )
                .background(accent.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(item.nowSpeakingTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(item.displayAgent)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let workspaceLabel = item.workspaceDisplayLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .foregroundStyle(accent.opacity(0.9))
                            .accessibilityHidden(true)
                        Text(workspaceLabel)
                            .fontWeight(.semibold)
                            .truncationMode(.middle)
                        if let worktreeLabel = item.workspaceWorktreeLabel {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(worktreeLabel)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        item.workspaceWorktreeLabel.map {
                            "Project \(workspaceLabel), worktree \($0)"
                        } ?? "Project \(workspaceLabel)"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if sessionOpener.canOpen(rawIdentifier: item.iTermSessionID) {
                Button {
                    sessionOpener.open(rawIdentifier: item.iTermSessionID)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Open agent session")
                .accessibilityLabel("Open agent session")
            }

        }
    }

    func pendingPreviewStatus(for item: TTSItem) -> some View {
        HStack(spacing: 8) {
            if item.status == .generating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "clock")
            }
            Text(item.status == .generating ? "Generating audio…" : "Audio ready — waiting to play")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.status == .generating ? "Generating audio" : "Audio ready and waiting to play")
    }

    func attachmentStrip(item: TTSItem, accent: Color) -> some View {
        HStack(spacing: 8) {
            if item.isAttachmentPlayback {
                Button {
                    presentation.selectAttachment(nil)
                    controller.returnToParent(from: item)
                } label: {
                    Label("Main update", systemImage: "arrow.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Return to the main message")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(item.briefAttachments) { attachment in
                        attachmentButton(attachment, item: item, accent: accent)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }

    func attachmentButton(
        _ attachment: TTSAttachment,
        item: TTSItem,
        accent: Color
    ) -> some View {
        let selected = presentation.selectedAttachmentID == attachment.id
            || item.attachmentID == attachment.id
        return Button {
            activateAttachment(attachment, item: item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: attachmentSymbol(attachment))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.black.opacity(0.76) : accent)

                Text(attachment.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if attachment.status == .preparing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.66)
                        .frame(width: 10, height: 10)
                } else if attachment.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? accent : Color.white.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? accent.opacity(0) : accent.opacity(0.18), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .help(attachmentHelp(attachment))
        .accessibilityLabel(attachment.label)
        .accessibilityValue(attachment.status.rawValue)
    }

    func activateAttachment(_ attachment: TTSAttachment, item: TTSItem) {
        let selected = presentation.selectedAttachmentID == attachment.id
            || item.attachmentID == attachment.id
        switch attachment.kind {
        case .image:
            presentation.selectAttachment(
                selected ? nil : attachment.id,
                image: selected ? nil : NSImage(contentsOfFile: attachment.sourceFile)
            )
        case .diagram:
            presentation.selectAttachment(
                selected ? nil : attachment.id,
                text: selected ? nil : (attachment.displayText ?? attachment.text)
            )
        case .narratedText, .audio:
            if attachment.isPlayable {
                if item.isAttachmentPlayback, item.attachmentID == attachment.id {
                    presentation.selectAttachment(nil)
                } else {
                    presentation.selectAttachment(attachment.id, text: attachment.displayText)
                    controller.playAttachment(attachment, from: item)
                }
            } else {
                presentation.selectAttachment(attachment.id, text: attachment.displayText)
            }
        case .file:
            controller.openAttachment(attachment)
        }
    }

    @ViewBuilder
    func attachmentPreview(
        _ attachment: TTSAttachment,
        item: TTSItem,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    presentation.selectAttachment(nil)
                } label: {
                    Label("Main transcript", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)

                Text(attachment.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button {
                    controller.openAttachment(attachment)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open attachment")
            }

            if attachment.kind == .diagram,
               let source = presentation.selectedAttachmentText ?? attachment.text
            {
                MermaidDiagramView(
                    source: source,
                    accentHue: WorkspaceAccent.paletteIndex(forWorkspacePath: item.workspacePath)
                )
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if attachment.kind == .image,
                      let image = presentation.selectedAttachmentImage
            {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if let text = presentation.selectedAttachmentText ?? attachment.text {
                ScrollView {
                    Text(markdownPreview(text))
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))

                if attachment.status == .preparing {
                    Label("Preparing narration…", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if attachment.isPlayable {
                    Button {
                        controller.playAttachment(attachment, from: item)
                    } label: {
                        Label("Play narration", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                } else if let error = attachment.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "doc")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(accent)
                    Text("Preview unavailable")
                        .font(.headline)
                    Text("Open the attachment in its default app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func selectedAttachment(for item: TTSItem) -> TTSAttachment? {
        guard let selectedID = presentation.selectedAttachmentID else { return nil }
        return item.briefAttachments.first(where: { $0.id == selectedID })
    }

    func attachmentSymbol(_ attachment: TTSAttachment) -> String {
        switch attachment.kind {
        case .narratedText: attachment.isPlayable ? "waveform" : "doc.text"
        case .image: "photo"
        case .diagram: "flowchart"
        case .audio: "speaker.wave.2"
        case .file: "paperclip"
        }
    }

    func attachmentHelp(_ attachment: TTSAttachment) -> String {
        switch (attachment.kind, attachment.status) {
        case (_, .failed): attachment.error ?? "Attachment preparation failed"
        case (.narratedText, .preparing): "Read while narration is prepared"
        case (.narratedText, .ready), (.audio, .ready): "Play \(attachment.label)"
        case (.image, _), (.diagram, _): "Preview \(attachment.label)"
        case (.file, _): "Open \(attachment.label)"
        case (.audio, .preparing): "Preparing audio"
        }
    }

    func markdownPreview(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(value)
    }

}
