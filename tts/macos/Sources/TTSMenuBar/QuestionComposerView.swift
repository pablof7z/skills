import AppKit
import SwiftUI

extension NowSpeakingHUDView {
    func questionTabs(_ questions: [TTSQuestion], accent: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    let selected = questionComposer.selectedQuestionID == question.id
                    let status = questionComposer.status(for: question.id)
                    Button {
                        questionComposer.navigate(to: question.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .frame(width: 18, height: 18)
                                .background(selected ? Color.black.opacity(0.16) : accent.opacity(0.13), in: Circle())
                            Text(question.shortTitle?.nonemptyValue ?? question.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if let symbol = questionStatusSymbol(status) {
                                Image(systemName: symbol)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.primary)
                        .background(
                            selected ? accent : Color.white.opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Question \(index + 1): \(question.title)")
                    .accessibilityValue(status.rawValue.capitalized)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Question tabs")
    }

    func suggestionCard(
        _ suggestion: TTSSuggestion,
        id: String,
        question: TTSQuestion,
        item: TTSItem,
        selected: Bool,
        accent: Color
    ) -> some View {
        let draft = questionComposer.draft(for: question.id)
        let suggestionDraft = draft.suggestion(id)
        let displayTitle = suggestionDraft?.isEdited == true
            ? suggestionDraft?.title ?? suggestion.title
            : suggestion.title
        let displayDescription = suggestionDraft?.isEdited == true
            ? suggestionDraft?.description
            : suggestion.description
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    questionComposer.selectSuggestion(
                        id: id,
                        title: displayTitle,
                        description: displayDescription,
                        for: question.id
                    )
                } label: {
                    Image(systemName: choiceSymbol(for: question.type, selected: selected))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? accent : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(question.type == .multipleChoice && selected ? "Deselect" : "Select") \(displayTitle)"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = displayDescription?.nonemptyValue {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay {
                    ImmediateClickTarget(
                        onSingleClick: {
                            questionComposer.selectSuggestion(
                                id: id,
                                title: displayTitle,
                                description: displayDescription,
                                for: question.id
                            )
                        },
                        onDoubleClick: {
                            openSuggestionEditor(suggestion, id: id, questionID: question.id)
                        }
                    )
                }

                Button {
                    openSuggestionEditor(suggestion, id: id, questionID: question.id)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Personalize this suggestion")
                .accessibilityLabel("Personalize \(displayTitle)")
            }

            if let attachments = suggestion.attachments, !attachments.isEmpty {
                compactAttachmentButtons(attachments, item: item, accent: accent)
            }

            if let suggestionDraft, suggestionDraft.isEdited, !suggestionDraft.attachmentURLs.isEmpty {
                answerAttachmentChips(
                    suggestionDraft.attachmentURLs,
                    questionID: question.id,
                    suggestionID: id,
                    accent: accent
                )
            }
        }
        .padding(11)
        .background(
            selected ? accent.opacity(0.16) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? accent : accent.opacity(0.14), lineWidth: selected ? 1.2 : 0.7)
        }
        .accessibilityLabel(displayTitle)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(
            question.type == .multipleChoice
                ? "Click to toggle this option. Double-click or use the pencil to personalize."
                : "Click to select without changing the freeform answer. Double-click or use the pencil to personalize."
        )
    }

    func answerAttachmentChips(
        _ urls: [URL],
        questionID: String,
        suggestionID: String?,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(urls, id: \.standardizedFileURL.path) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                        Button {
                            if let suggestionID {
                                questionComposer.removeEditedSuggestionAttachment(
                                    url,
                                    suggestionID: suggestionID,
                                    for: questionID
                                )
                            } else {
                                questionComposer.removeAttachment(url, for: questionID)
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
                    .background(accent.opacity(0.1), in: Capsule())
                }
            }
            .padding(.vertical, 1)
        }
    }

    func contextAttachmentRow(
        _ attachments: [TTSAttachment],
        label: String,
        item: TTSItem,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            compactAttachmentButtons(attachments, item: item, accent: accent)
        }
    }

    func compactAttachmentButtons(
        _ attachments: [TTSAttachment],
        item: TTSItem,
        accent: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    Button {
                        openSupportingAttachment(attachment, item: item)
                    } label: {
                        Label(attachment.label, systemImage: attachmentSymbol(attachment))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help(attachmentHelp(attachment))
                }
            }
            .padding(.vertical, 1)
        }
    }

    func sentResponse(_ response: TTSResponse, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Answer sent")
                    .font(.subheadline.weight(.semibold))
                if let answer = response.answer.nonemptyValue {
                    Text(answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let attachments = response.attachments, !attachments.isEmpty {
                    ForEach(attachments) { attachment in
                        Label(attachment.sourceFile, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

}
