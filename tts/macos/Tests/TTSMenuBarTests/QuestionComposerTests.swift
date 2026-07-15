import Foundation
import Testing
@testable import TTSMenuBar

struct QuestionComposerTests {
    @Test
    func tabDraftsRemainIsolated() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["scope", "timing"])
        model.updateDraft("Keep the first release narrow", for: "scope")
        model.selectQuestion("timing")
        model.updateDraft("Ship after the smoke test", for: "timing")

        #expect(model.draft(for: "scope").freeformText == "Keep the first release narrow")
        #expect(model.draft(for: "timing").freeformText == "Ship after the smoke test")
        #expect(model.selectedQuestionID == "timing")
    }

    @Test
    func selectingSuggestionDoesNotCopyItsTitleIntoFreeformDraft() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["timing"])
        model.selectSuggestion(id: "ship", title: "Ship today", for: "timing")

        #expect(model.draft(for: "timing").freeformText.isEmpty)
        #expect(model.draft(for: "timing").selectedSuggestionID == "ship")
        #expect(model.submissions(questionIDs: ["timing"]).first?.answer == "Ship today")
    }

    @Test
    func radioSelectionReplacesPriorChoice() {
        var model = QuestionComposerModel()
        model.prepare(questions: [QuestionChoiceConfiguration(id: "timing", type: .singleChoice)])
        model.selectSuggestion(id: "ship", title: "Ship today", for: "timing")
        model.selectSuggestion(id: "wait", title: "Wait for tests", for: "timing")

        let submission = model.submissions(questionIDs: ["timing"])[0]
        #expect(submission.suggestionIDs == ["wait"])
        #expect(submission.answer == "Wait for tests")
    }

    @Test
    func radioSelectionPreservesAnExistingFreeformDraftWithoutUsingIt() {
        var model = QuestionComposerModel()
        model.prepare(questions: [QuestionChoiceConfiguration(id: "timing", type: .singleChoice)])
        model.updateDraft("My earlier draft", for: "timing")
        model.selectSuggestion(id: "ship", title: "Ship", for: "timing")

        #expect(model.draft(for: "timing").freeformText == "My earlier draft")
        #expect(model.submissions(questionIDs: ["timing"])[0].answer == "Ship")
    }

    @Test
    func checkboxSelectionTogglesAndPreservesSelectionOrder() {
        var model = QuestionComposerModel()
        model.prepare(questions: [QuestionChoiceConfiguration(id: "scope", type: .multipleChoice)])
        model.selectSuggestion(id: "api", title: "API", for: "scope")
        model.selectSuggestion(id: "ui", title: "UI", for: "scope")
        model.selectSuggestion(id: "api", title: "API", for: "scope")

        #expect(model.submissions(questionIDs: ["scope"])[0].suggestionIDs == ["ui"])

        model.selectSuggestion(id: "api", title: "API", for: "scope")
        let submission = model.submissions(questionIDs: ["scope"])[0]
        #expect(submission.suggestionIDs == ["ui", "api"])
        #expect(submission.answer == "UI, API")
    }

    @Test
    func multipleChoiceEditsAndAttachmentsStayScopedPerSuggestion() {
        var model = QuestionComposerModel()
        model.prepare(questions: [QuestionChoiceConfiguration(id: "scope", type: .multipleChoice)])
        let apiFile = URL(fileURLWithPath: "/tmp/api.md")
        let uiFile = URL(fileURLWithPath: "/tmp/ui.png")
        model.applySuggestionEdit(
            title: "API after compatibility review",
            description: "Keep compatibility with existing clients.",
            suggestionID: "api",
            attachments: [apiFile],
            for: "scope"
        )
        model.applySuggestionEdit(
            title: "UI with the compact layout",
            description: "Use the dense presentation.",
            suggestionID: "ui",
            attachments: [uiFile],
            for: "scope"
        )

        #expect(model.draft(for: "scope").suggestion("api")?.attachmentURLs == [apiFile])
        #expect(model.draft(for: "scope").suggestion("ui")?.attachmentURLs == [uiFile])
        let submission = model.submissions(questionIDs: ["scope"])[0]
        #expect(submission.suggestionIDs == ["api", "ui"])
        #expect(submission.answer == "API after compatibility review, UI with the compact layout")
        #expect(submission.selectedSuggestions == [
            TTSQuestionDraftSuggestion(
                id: "api",
                title: "API after compatibility review",
                description: "Keep compatibility with existing clients."
            ),
            TTSQuestionDraftSuggestion(
                id: "ui",
                title: "UI with the compact layout",
                description: "Use the dense presentation."
            ),
        ])
        #expect(submission.attachmentURLs == [apiFile.path, uiFile.path])
    }

    @Test
    func multipleChoiceFreeformIsAnAdditionalNote() {
        var model = QuestionComposerModel()
        model.prepare(questions: [QuestionChoiceConfiguration(id: "scope", type: .multipleChoice)])
        model.selectSuggestion(id: "api", title: "API", for: "scope")
        model.selectSuggestion(id: "ui", title: "UI", for: "scope")
        model.updateDraft("Keep the rollout reversible", for: "scope")

        let submission = model.submissions(questionIDs: ["scope"])[0]
        #expect(submission.suggestionIDs == ["api", "ui"])
        #expect(submission.answer == "API, UI\n\nAdditional note: Keep the rollout reversible")
    }

    @Test
    func legacyQuestionDefaultsToSingleChoiceMode() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["timing"])
        model.selectSuggestion(id: "ship", title: "Ship today", for: "timing")
        model.updateDraft("Wait for the smoke test", for: "timing")

        let submission = model.submissions(questionIDs: ["timing"]).first
        #expect(submission?.answer == "Wait for the smoke test")
        #expect(submission?.suggestionID == nil)
    }

    @Test
    func editedSuggestionAndItsAttachmentsRemainAssociatedWithQuestion() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["timing"])
        let attachment = URL(fileURLWithPath: "/tmp/release-checklist.md")
        model.applySuggestionEdit(
            title: "Ship today after the smoke test",
            description: "Wait for the final smoke test result.",
            suggestionID: "ship",
            attachments: [attachment],
            for: "timing"
        )

        let submission = model.submissions(questionIDs: ["timing"]).first
        #expect(submission?.answer == "Ship today after the smoke test")
        #expect(submission?.suggestionID == "ship")
        #expect(submission?.selectedSuggestions.first?.description == "Wait for the final smoke test result.")
        #expect(submission?.attachmentURLs == [attachment.path])
    }

    @Test
    func droppedAttachmentsAreDeduplicatedAndRemovable() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["evidence"])
        let first = URL(fileURLWithPath: "/tmp/evidence.png")
        let second = URL(fileURLWithPath: "/tmp/notes.md")
        model.addAttachments([first, first, second], for: "evidence")

        #expect(model.draft(for: "evidence").attachmentURLs == [first, second])

        model.removeAttachment(first, for: "evidence")

        #expect(model.draft(for: "evidence").attachmentURLs == [second])
    }

    @Test
    func savedFreeformAnswerCanBeClearedBackToSkipped() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["scope"])
        model.updateDraft("Keep it narrow", for: "scope")
        model.setAttachments([URL(fileURLWithPath: "/tmp/context.md")], for: "scope")

        model.updateDraft("", for: "scope")
        model.setAttachments([], for: "scope")

        #expect(model.draft(for: "scope").freeformText.isEmpty)
        #expect(model.submissions(questionIDs: ["scope"])[0].isSkipped)
    }

    @Test
    func mixedBlankSubmissionMarksBlankQuestionsAsSkipped() {
        var model = QuestionComposerModel()
        model.prepare(questionIDs: ["scope", "timing", "evidence"])
        model.updateDraft("  Keep it narrow  ", for: "scope")
        model.addAttachments([URL(fileURLWithPath: "/tmp/proof.png")], for: "evidence")

        let submissions = model.submissions(questionIDs: ["scope", "timing", "evidence"])

        #expect(submissions[0].answer == "Keep it narrow")
        #expect(!submissions[0].isSkipped)
        #expect(submissions[1].isSkipped)
        #expect(submissions[2].answer == nil)
        #expect(!submissions[2].isSkipped)
    }
}
