import Testing
@testable import TTSMenuBar

struct QuestionIndicatorTests {
    @Test
    func distinguishesPendingAnsweredAndOtherResolvedQuestions() {
        var question = QueueStoreTests().item(id: "question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        #expect(QuestionIndicatorState(item: question) == .pending)
        #expect(QuestionIndicatorState(item: question).systemImage == "questionmark.bubble.fill")

        question.questionStatus = .answered
        #expect(QuestionIndicatorState(item: question) == .answered)
        #expect(QuestionIndicatorState(item: question).systemImage == "checkmark.bubble.fill")
        #expect(QuestionIndicatorState(item: question).accessibilityLabel == "Answered question")

        question.questionStatus = .skipped
        #expect(QuestionIndicatorState(item: question) == .resolved)
        #expect(QuestionIndicatorState(item: question).systemImage == "questionmark.bubble.fill")
    }
}
