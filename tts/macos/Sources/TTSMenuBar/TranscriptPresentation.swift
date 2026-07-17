import Foundation

struct TranscriptWord: Equatable {
    let range: NSRange
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let phraseIndex: Int

    var hasPreciseTiming: Bool {
        startTime != nil && endTime != nil
    }
}

struct TranscriptPhrase: Equatable {
    let range: NSRange
    let wordRange: Range<Int>
    let startTime: TimeInterval?
    let endTime: TimeInterval?
}

struct TranscriptPlaybackState: Equatable {
    let activeWordIndex: Int?
    let activePhraseIndex: Int?
}

struct TranscriptDocument: Equatable {
    let text: String
    let words: [TranscriptWord]
    let phrases: [TranscriptPhrase]

    static func build(
        text: String,
        timings: [TTSWordTiming]?,
        duration: TimeInterval
    ) -> TranscriptDocument {
        build(
            attributedText: NSAttributedString(string: text),
            timings: timings,
            duration: duration
        )
    }

    static func build(
        attributedText: NSAttributedString,
        timings: [TTSWordTiming]?,
        duration: TimeInterval
    ) -> TranscriptDocument {
        let text = attributedText.string
        let sourceRanges = sourceWordRanges(in: attributedText)
        guard !sourceRanges.isEmpty else {
            return TranscriptDocument(text: text, words: [], phrases: [])
        }

        let source = text as NSString
        let aligned = TranscriptTimingAlignment.align(
            sourceTokens: sourceRanges.map { source.substring(with: $0) },
            timings: timings
        )
        let phraseRanges = buildPhrases(sourceRanges: sourceRanges, aligned: aligned, text: text)
        var phraseIndexByWord = Array(repeating: 0, count: sourceRanges.count)
        for (phraseIndex, wordRange) in phraseRanges.enumerated() {
            for wordIndex in wordRange {
                phraseIndexByWord[wordIndex] = phraseIndex
            }
        }

        let words = sourceRanges.enumerated().map { index, range in
            TranscriptWord(
                range: range,
                startTime: aligned[index]?.startTime,
                endTime: aligned[index]?.endTime,
                phraseIndex: phraseIndexByWord[index]
            )
        }
        let phrases = phraseRanges.map { wordRange in
            let first = sourceRanges[wordRange.lowerBound]
            let last = sourceRanges[wordRange.upperBound - 1]
            let phraseTimings = aligned[wordRange].compactMap { $0 }
            return TranscriptPhrase(
                range: NSRange(
                    location: first.location,
                    length: NSMaxRange(last) - first.location
                ),
                wordRange: wordRange,
                startTime: phraseTimings.first?.startTime,
                endTime: phraseTimings.last?.endTime
            )
        }

        return TranscriptDocument(text: text, words: words, phrases: phrases)
    }

    func playbackState(at time: TimeInterval, duration: TimeInterval) -> TranscriptPlaybackState {
        let preciseIndices = words.indices.filter { words[$0].startTime != nil }
        if !preciseIndices.isEmpty {
            var low = 0
            var high = preciseIndices.count
            while low < high {
                let middle = (low + high) / 2
                let index = preciseIndices[middle]
                if (words[index].startTime ?? .infinity) <= time {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0 else {
                return TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: nil)
            }
            let resolved = preciseIndices[low - 1]
            let activeWordIndex: Int?
            if let endTime = words[resolved].endTime, time <= endTime {
                activeWordIndex = resolved
            } else {
                activeWordIndex = nil
            }
            return TranscriptPlaybackState(
                activeWordIndex: activeWordIndex,
                activePhraseIndex: words[resolved].phraseIndex
            )
        }

        guard duration > 0, !phrases.isEmpty else {
            return TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: nil)
        }
        let progress = min(max(time / duration, 0), 0.999_999)
        let phraseIndex = min(Int(progress * Double(phrases.count)), phrases.count - 1)
        return TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: phraseIndex)
    }

    func seekTime(forWordAt index: Int, duration: TimeInterval) -> TimeInterval {
        guard words.indices.contains(index) else { return 0 }
        if let precise = words[index].startTime {
            return precise
        }
        guard duration > 0, !words.isEmpty else { return 0 }
        return duration * Double(index) / Double(words.count)
    }

    func wordIndex(at characterIndex: Int) -> Int? {
        words.firstIndex { NSLocationInRange(characterIndex, $0.range) }
    }

    private static func sourceWordRanges(in text: NSAttributedString) -> [NSRange] {
        let pattern = #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: (text.string as NSString).length)
        return expression.matches(in: text.string, range: range)
            .map(\.range)
            .filter { wordRange in
                text.attribute(.transcriptNonSpoken, at: wordRange.location, effectiveRange: nil) == nil
            }
    }

    private static func buildPhrases(
        sourceRanges: [NSRange],
        aligned: [TranscriptAlignedTiming?],
        text: String
    ) -> [Range<Int>] {
        guard !sourceRanges.isEmpty else { return [] }
        let source = text as NSString
        var result: [Range<Int>] = []
        var phraseStart = 0

        for index in sourceRanges.indices.dropLast() {
            let nextIndex = index + 1
            let gapRange = NSRange(
                location: NSMaxRange(sourceRanges[index]),
                length: sourceRanges[nextIndex].location - NSMaxRange(sourceRanges[index])
            )
            let separator = gapRange.length > 0 ? source.substring(with: gapRange) : ""
            let wordCount = nextIndex - phraseStart
            let phraseDuration: TimeInterval = {
                guard let start = aligned[phraseStart]?.startTime,
                      let end = aligned[index]?.endTime else { return 0 }
                return end - start
            }()
            let pause: TimeInterval = {
                guard let end = aligned[index]?.endTime,
                      let start = aligned[nextIndex]?.startTime else { return 0 }
                return start - end
            }()

            let strongBoundary = separator.range(of: #"[.!?;:\n]"#, options: .regularExpression) != nil
            let softBoundary = separator.range(of: #"[,—–]"#, options: .regularExpression) != nil
            let shouldBreak = strongBoundary
                || pause >= 0.32
                || (softBoundary && wordCount >= 3)
                || wordCount >= 12
                || phraseDuration >= 4

            if shouldBreak {
                result.append(phraseStart..<nextIndex)
                phraseStart = nextIndex
            }
        }
        result.append(phraseStart..<sourceRanges.count)
        return result
    }

}
