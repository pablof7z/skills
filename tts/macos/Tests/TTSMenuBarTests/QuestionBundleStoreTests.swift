import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test
    func submitsBundleWithMixedAnsweredAndSkippedQuestionsOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "bundle")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: "Use the shared model"),
                TTSQuestionDraft(questionID: "q-02", answer: "   "),
            ],
            actor: "test-agent",
            now: 40
        )

        #expect(submitted.questionStatus == .answered)
        #expect(submitted.questions?[0].status == .answered)
        #expect(submitted.questions?[0].response?.answer == "Use the shared model")
        #expect(submitted.questions?[0].response?.answeredAt == 40)
        #expect(submitted.questions?[1].status == .skipped)
        #expect(submitted.questions?[1].response == nil)
        let operations = try FileManager.default.contentsOfDirectory(
            at: store.operationsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(operations.count == 1)
        let operation = try JSONDecoder().decode(
            QueueOperation.self,
            from: Data(contentsOf: operations[0])
        )
        #expect(operation.kind == .answer)
        #expect(operation.sourceIDs == [bundle.id])
        #expect(operation.actor == "test-agent")
        #expect(throws: QueueOperationError.questionAlreadyResolved(bundle.id)) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(questionID: "q-01", answer: "Again"),
                    TTSQuestionDraft(questionID: "q-02", answer: "Again"),
                ]
            )
        }
    }

    @Test
    func allBlankBundleDraftsResolveAsSkipped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "all-skipped")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: ""),
                TTSQuestionDraft(questionID: "q-02", answer: "\n  "),
            ]
        )

        #expect(submitted.questionStatus == .answered)
        #expect(submitted.questions?.allSatisfy { $0.status == .skipped } == true)
        #expect(submitted.questions?.allSatisfy { $0.response == nil } == true)
    }

    @Test
    func bundleSuggestionUsesStableIDAndTracksEditedAnswer() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "suggested")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Use the shared model after validation",
                    suggestionID: "q-01-s-01",
                    selectedSuggestions: [TTSQuestionDraftSuggestion(
                        id: "q-01-s-01",
                        title: "Use the shared model after validation",
                        description: "Keep ownership shared after the validation pass."
                    )]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: "No change"),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.suggestionID == "q-01-s-01")
        #expect(response.suggestionIDs == ["q-01-s-01"])
        #expect(response.suggestionIndex == 0)
        #expect(response.modified)
        #expect(response.answer == "Use the shared model after validation")
        #expect(response.selectedSuggestions == [TTSSelectedSuggestion(
            id: "q-01-s-01",
            title: "Use the shared model after validation",
            description: "Keep ownership shared after the validation pass.",
            modified: true
        )])
    }

    @Test
    func descriptionOnlySuggestionEditIsReturnedAndMarkedModified() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        let bundle = bundleItem(id: "description-edit")
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Use the shared model",
                    suggestionID: "q-01-s-01",
                    selectedSuggestions: [TTSQuestionDraftSuggestion(
                        id: "q-01-s-01",
                        title: "Use the shared model",
                        description: "Keep one source of truth and document its owner."
                    )]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.modified)
        #expect(response.selectedSuggestions?.first?.title == "Use the shared model")
        #expect(
            response.selectedSuggestions?.first?.description
                == "Keep one source of truth and document its owner."
        )
    }

    @Test
    func suggestionDetailOrderMismatchIsRejectedAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "detail-mismatch")
        bundle.questions?[0].type = .multipleChoice
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(title: "Split the model", id: "q-01-s-02")
        )
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidBundleDrafts(
            "selected suggestion details must match selected ID order for question q-01"
        )) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Use the shared model, Split the model",
                        suggestionIDs: ["q-01-s-01", "q-01-s-02"],
                        selectedSuggestions: [
                            TTSQuestionDraftSuggestion(id: "q-01-s-02", title: "Split the model"),
                            TTSQuestionDraftSuggestion(id: "q-01-s-01", title: "Use the shared model"),
                        ]
                    ),
                    TTSQuestionDraft(questionID: "q-02", answer: ""),
                ]
            )
        }
        #expect(try store.item(id: bundle.id)?.questionStatus == .pending)
    }

    @Test
    func multipleChoicePreservesOrderedStableSuggestionIDs() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "multiple")
        bundle.questions?[0].type = .multipleChoice
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(
                title: "Split the model",
                description: "Use distinct ownership.",
                id: "q-01-s-02"
            )
        )
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "Split the model, Use the shared model",
                    suggestionIDs: ["q-01-s-02", "q-01-s-01"],
                    selectedSuggestions: [
                        TTSQuestionDraftSuggestion(
                            id: "q-01-s-02",
                            title: "Split the model",
                            description: "Use distinct ownership."
                        ),
                        TTSQuestionDraftSuggestion(
                            id: "q-01-s-01",
                            title: "Use the shared model",
                            description: "Keep one source of truth."
                        ),
                    ]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )

        let response = try #require(submitted.questions?[0].response)
        #expect(response.answer == "Split the model, Use the shared model")
        #expect(response.suggestionIDs == ["q-01-s-02", "q-01-s-01"])
        #expect(response.suggestionID == nil)
        #expect(response.suggestionIndex == nil)
        #expect(!response.modified)
        #expect(response.selectedSuggestions?.map(\.id) == ["q-01-s-02", "q-01-s-01"])
    }

    @Test
    func singleChoiceRejectsMultipleSelectedSuggestionIDsAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var bundle = bundleItem(id: "single")
        bundle.questions?[0].suggestions?.append(
            TTSSuggestion(
                title: "Split the model",
                description: "Use distinct ownership.",
                id: "q-01-s-02"
            )
        )
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidBundleDrafts(
            "question q-01 accepts only one suggestion"
        )) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Use both",
                        suggestionIDs: ["q-01-s-01", "q-01-s-02"]
                    ),
                    TTSQuestionDraft(questionID: "q-02", answer: ""),
                ]
            )
        }
        let persisted = try #require(try store.item(id: bundle.id))
        #expect(persisted.questionStatus == .pending)
        #expect(persisted.questions?.allSatisfy { $0.status == .pending } == true)
    }

    @Test
    func questionTypeDefaultsToSingleChoiceWhenLegacyJSONOmitsIt() throws {
        let question = try JSONDecoder().decode(
            TTSQuestion.self,
            from: Data(#"{"id":"q-01","title":"Legacy question","status":"pending"}"#.utf8)
        )

        #expect(question.type == .singleChoice)
    }

    @Test
    func responseRoundTripsPluralSuggestionIDsAlongsideLegacyFields() throws {
        let original = TTSResponse(
            answer: "First, Second",
            suggestionIndex: nil,
            modified: false,
            answeredAt: 50,
            interaction: "suggestion",
            suggestionID: nil,
            suggestionIDs: ["first", "second"],
            selectedSuggestions: [
                TTSSelectedSuggestion(
                    id: "first",
                    title: "First",
                    description: "First detail",
                    modified: false
                ),
                TTSSelectedSuggestion(
                    id: "second",
                    title: "Second revised",
                    description: nil,
                    modified: true
                ),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["suggestion_ids"] as? [String] == ["first", "second"])
        #expect(object["suggestion_id"] == nil)
        #expect((object["selected_suggestions"] as? [[String: Any]])?.count == 2)
        let decoded = try JSONDecoder().decode(TTSResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func copiesAnswerAttachmentsIntoCollisionSafeDurableAssets() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = directory.appendingPathComponent("originals", isDirectory: true)
        let firstDirectory = originals.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = originals.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("evidence.txt")
        let second = secondDirectory.appendingPathComponent("evidence.txt")
        try Data("first evidence".utf8).write(to: first)
        try Data("second evidence".utf8).write(to: second)
        let store = QueueStore(stateDirectory: directory.appendingPathComponent("state", isDirectory: true))
        var bundle = bundleItem(id: "attachments")
        bundle.assetDirectory = directory.appendingPathComponent("durable", isDirectory: true).path
        try store.save(bundle)

        let submitted = try store.submitBundle(
            id: bundle.id,
            drafts: [
                TTSQuestionDraft(
                    questionID: "q-01",
                    answer: "",
                    attachmentURLs: [first, second]
                ),
                TTSQuestionDraft(questionID: "q-02", answer: ""),
            ]
        )
        let attachments = try #require(submitted.questions?[0].response?.attachments)
        #expect(submitted.questions?[0].status == .answered)
        #expect(submitted.questions?[0].response?.answer == "")
        #expect(attachments.count == 2)
        #expect(Set(attachments.map(\.sourceFile)).count == 2)
        #expect(attachments.map(\.label) == ["evidence.txt", "evidence.txt"])

        try FileManager.default.removeItem(at: originals)
        let persisted = try #require(try store.item(id: bundle.id))
        let durable = try #require(persisted.questions?[0].response?.attachments)
        #expect(durable.allSatisfy { FileManager.default.fileExists(atPath: $0.sourceFile) })
        #expect(
            Set(try durable.map { try String(contentsOfFile: $0.sourceFile, encoding: .utf8) })
                == Set(["first evidence", "second evidence"])
        )
    }

    @Test
    func invalidBundleDraftLeavesStateAndAssetsUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("answer.txt")
        try Data("answer".utf8).write(to: source)
        let store = QueueStore(stateDirectory: directory.appendingPathComponent("state", isDirectory: true))
        var bundle = bundleItem(id: "atomic")
        bundle.assetDirectory = directory.appendingPathComponent("durable", isDirectory: true).path
        try store.save(bundle)

        #expect(throws: QueueOperationError.invalidSuggestionID("missing")) {
            try store.submitBundle(
                id: bundle.id,
                drafts: [
                    TTSQuestionDraft(
                        questionID: "q-01",
                        answer: "Valid so far",
                        attachmentURLs: [source]
                    ),
                    TTSQuestionDraft(
                        questionID: "q-02",
                        answer: "Invalid",
                        suggestionID: "missing"
                    ),
                ]
            )
        }

        let persisted = try #require(try store.item(id: bundle.id))
        #expect(persisted.questionStatus == .pending)
        #expect(persisted.questions?.allSatisfy { $0.status == .pending && $0.response == nil } == true)
        #expect(
            (try FileManager.default.contentsOfDirectory(
                at: store.operationsDirectory,
                includingPropertiesForKeys: nil
            )).isEmpty
        )
        #expect(!FileManager.default.fileExists(atPath: bundle.assetDirectory!))
    }

    @Test
    func decodesLegacySuggestionResponseAndAttachmentWithoutNewFields() throws {
        let suggestion = try JSONDecoder().decode(
            TTSSuggestion.self,
            from: Data(#"{"title":"Legacy","description":"Old pair"}"#.utf8)
        )
        let response = try JSONDecoder().decode(
            TTSResponse.self,
            from: Data(#"{"answer":"Yes","suggestion_index":0,"modified":false,"answered_at":12,"interaction":"suggestion"}"#.utf8)
        )
        let attachment = try JSONDecoder().decode(
            TTSAttachment.self,
            from: Data(#"{"id":"a","label":"A","kind":"file","status":"ready","source_file":"/tmp/a"}"#.utf8)
        )

        #expect(suggestion.id == nil)
        #expect(suggestion.attachments == nil)
        #expect(response.suggestionIndex == 0)
        #expect(response.suggestionID == nil)
        #expect(response.attachments == nil)
        #expect(attachment.description == nil)
    }

    @Test
    func stalePlaybackSaveCannotClobberTerminalBundleResponses() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(stateDirectory: directory)
        var stale = bundleItem(id: "concurrent")
        try store.save(stale)
        _ = try store.submitBundle(
            id: stale.id,
            drafts: [
                TTSQuestionDraft(questionID: "q-01", answer: "Durable first"),
                TTSQuestionDraft(questionID: "q-02", answer: "Durable second"),
            ]
        )

        stale.status = .played
        try store.save(stale)

        let persisted = try #require(try store.item(id: stale.id))
        #expect(persisted.status == .played)
        #expect(persisted.questionStatus == .answered)
        #expect(persisted.questions?.map { $0.response?.answer } == ["Durable first", "Durable second"])
        #expect(persisted.questions?.allSatisfy { $0.status == .answered } == true)
    }

}
