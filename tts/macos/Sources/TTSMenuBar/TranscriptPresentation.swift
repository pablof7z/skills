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

        let aligned = align(sourceRanges: sourceRanges, in: text, timings: timings)
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
            return TranscriptPhrase(
                range: NSRange(
                    location: first.location,
                    length: NSMaxRange(last) - first.location
                ),
                wordRange: wordRange,
                startTime: aligned[wordRange.lowerBound]?.startTime,
                endTime: aligned[wordRange.upperBound - 1]?.endTime
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
            guard let endTime = words[resolved].endTime, time <= endTime else {
                return TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: nil)
            }
            return TranscriptPlaybackState(
                activeWordIndex: resolved,
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

    private struct AlignedTiming: Equatable {
        var startTime: TimeInterval
        var endTime: TimeInterval
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

    private static func align(
        sourceRanges: [NSRange],
        in text: String,
        timings: [TTSWordTiming]?
    ) -> [AlignedTiming?] {
        guard let timings, !timings.isEmpty else {
            return Array(repeating: nil, count: sourceRanges.count)
        }

        var provider: [(normalized: String, timing: AlignedTiming)] = []
        for timing in timings where timing.startTime.isFinite && timing.endTime.isFinite {
            let normalized = normalizedToken(timing.word)
            if normalized.isEmpty {
                if !provider.isEmpty {
                    provider[provider.count - 1].timing.endTime = max(
                        provider[provider.count - 1].timing.endTime,
                        timing.endTime
                    )
                }
                continue
            }
            provider.append((
                normalized,
                AlignedTiming(startTime: max(0, timing.startTime), endTime: max(timing.startTime, timing.endTime))
            ))
        }
        guard !provider.isEmpty else {
            return Array(repeating: nil, count: sourceRanges.count)
        }

        let source = text as NSString
        let sourceTokens = sourceRanges.map { normalizedToken(source.substring(with: $0)) }
        var result = Array<AlignedTiming?>(repeating: nil, count: sourceRanges.count)
        let candidateStarts = provider.indices.filter {
            tokensCorrespond(sourceTokens[0], provider[$0].normalized)
        }
        var providerIndex = candidateStarts.max { left, right in
            let leftScore = alignmentScore(sourceTokens: sourceTokens, provider: provider, startingAt: left)
            let rightScore = alignmentScore(sourceTokens: sourceTokens, provider: provider, startingAt: right)
            return leftScore == rightScore ? left < right : leftScore < rightScore
        } ?? 0
        for (sourceIndex, range) in sourceRanges.enumerated() where providerIndex < provider.count {
            let normalizedSource = normalizedToken(source.substring(with: range))
            let match = (providerIndex..<provider.count).first {
                tokensCorrespond(normalizedSource, provider[$0].normalized)
            }
            guard let resolved = match else { continue }
            result[sourceIndex] = provider[resolved].timing
            providerIndex = resolved + 1
        }
        return result
    }

    private static func alignmentScore(
        sourceTokens: [String],
        provider: [(normalized: String, timing: AlignedTiming)],
        startingAt start: Int
    ) -> Int {
        var providerIndex = start
        var score = 0
        for sourceToken in sourceTokens where providerIndex < provider.count {
            guard let match = (providerIndex..<provider.count).first(where: {
                tokensCorrespond(sourceToken, provider[$0].normalized)
            }) else { continue }
            score += 1
            providerIndex = match + 1
        }
        return score
    }

    private static func buildPhrases(
        sourceRanges: [NSRange],
        aligned: [AlignedTiming?],
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

    private static func normalizedToken(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func tokensCorrespond(_ source: String, _ provider: String) -> Bool {
        guard !source.isEmpty, !provider.isEmpty else { return false }
        if source == provider { return true }
        guard min(source.count, provider.count) >= 3 else { return false }
        return source.contains(provider) || provider.contains(source)
    }
}
