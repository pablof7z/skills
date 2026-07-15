import Testing
@testable import TTSMenuBar

struct QuestionComposerTests {
    @Test
    func suggestionFillsComposerWithoutCreatingSubmissionSideEffects() throws {
        var model = QuestionComposerModel()
        let suggestion = TTSSuggestion(
            title: "Use the safer migration",
            description: "Keep the existing data until verification completes."
        )

        model.select(suggestion: suggestion, at: 1)

        #expect(model.draft == suggestion.title)
        #expect(model.selectedSuggestionIndex == 1)
        #expect(model.submission == QuestionSubmission(text: suggestion.title, suggestionIndex: 1))
    }

    @Test
    func selectedSuggestionRemainsIdentifiableAfterUserEditsIt() throws {
        var model = QuestionComposerModel()
        model.select(
            suggestion: TTSSuggestion(title: "Ship today", description: "Use the current scope."),
            at: 0
        )
        model.updateDraft("Ship today after the smoke test")

        #expect(
            model.submission
                == QuestionSubmission(text: "Ship today after the smoke test", suggestionIndex: 0)
        )
    }

    @Test
    func freeformComposerTrimsAnswerAndRejectsWhitespace() throws {
        var model = QuestionComposerModel()
        model.updateDraft("   \n")
        #expect(!model.canSend)
        #expect(model.submission == nil)

        model.updateDraft("  A different answer  ")
        #expect(model.canSend)
        #expect(model.submission == QuestionSubmission(text: "A different answer", suggestionIndex: nil))
    }

    @Test
    func resetClearsDraftAndSuggestionIdentity() throws {
        var model = QuestionComposerModel()
        model.select(
            suggestion: TTSSuggestion(title: "Wait", description: "Gather more evidence."),
            at: 2
        )

        model.reset()

        #expect(model.draft.isEmpty)
        #expect(model.selectedSuggestionIndex == nil)
        #expect(!model.canSend)
    }
}
