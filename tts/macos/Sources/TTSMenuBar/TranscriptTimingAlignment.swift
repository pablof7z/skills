import Foundation

struct TranscriptAlignedTiming: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptTimingAlignment {
    private struct SourceToken {
        let canonical: String
        let isNumeric: Bool
    }

    private struct ProviderToken {
        let canonical: String
        var timing: TranscriptAlignedTiming
    }

    private struct Match {
        let sourceCount: Int
        let providerCount: Int
    }

    private static let maximumCompoundLength = 8
    // A bad token must not jump across a sentence to a later repeated word.
    private static let maximumProviderLookahead = 12

    static func align(
        sourceTokens: [String],
        timings: [TTSWordTiming]?
    ) -> [TranscriptAlignedTiming?] {
        guard !sourceTokens.isEmpty else { return [] }
        let source = sourceTokens.map(sourceToken)
        let provider = providerTokens(from: timings)
        guard !provider.isEmpty else {
            return Array(repeating: nil, count: source.count)
        }

        let candidateStarts = provider.indices.filter {
            match(source: source, at: 0, provider: provider, at: $0) != nil
        }
        let providerStart = candidateStarts.max { left, right in
            let leftScore = alignmentScore(source: source, provider: provider, startingAt: left)
            let rightScore = alignmentScore(source: source, provider: provider, startingAt: right)
            return leftScore == rightScore ? left > right : leftScore < rightScore
        } ?? 0

        var result = Array<TranscriptAlignedTiming?>(repeating: nil, count: source.count)
        var sourceIndex = 0
        var providerIndex = providerStart
        while sourceIndex < source.count, providerIndex < provider.count {
            guard let resolved = nextMatch(
                source: source,
                at: sourceIndex,
                provider: provider,
                startingAt: providerIndex
            ) else {
                sourceIndex += 1
                continue
            }
            providerIndex = resolved.index
            apply(
                resolved.match,
                sourceIndex: sourceIndex,
                providerIndex: providerIndex,
                provider: provider,
                result: &result
            )
            sourceIndex += resolved.match.sourceCount
            providerIndex += resolved.match.providerCount
        }
        return result
    }

    private static func providerTokens(from timings: [TTSWordTiming]?) -> [ProviderToken] {
        guard let timings else { return [] }
        var result: [ProviderToken] = []
        for timing in timings where timing.startTime.isFinite && timing.endTime.isFinite {
            let canonical = providerCanonical(timing.word)
            if canonical.isEmpty {
                if let last = result.indices.last {
                    result[last].timing = TranscriptAlignedTiming(
                        startTime: result[last].timing.startTime,
                        endTime: max(result[last].timing.endTime, timing.endTime)
                    )
                }
                continue
            }
            result.append(ProviderToken(
                canonical: canonical,
                timing: TranscriptAlignedTiming(
                    startTime: max(0, timing.startTime),
                    endTime: max(timing.startTime, timing.endTime)
                )
            ))
        }
        return result
    }

    private static func alignmentScore(
        source: [SourceToken],
        provider: [ProviderToken],
        startingAt providerStart: Int
    ) -> Int {
        var score = 0
        var sourceIndex = 0
        var providerIndex = providerStart
        while sourceIndex < source.count, providerIndex < provider.count {
            guard let resolved = nextMatch(
                source: source,
                at: sourceIndex,
                provider: provider,
                startingAt: providerIndex
            ) else {
                sourceIndex += 1
                continue
            }
            score += resolved.match.sourceCount
            sourceIndex += resolved.match.sourceCount
            providerIndex = resolved.index + resolved.match.providerCount
        }
        return score
    }

    private static func nextMatch(
        source: [SourceToken],
        at sourceIndex: Int,
        provider: [ProviderToken],
        startingAt providerIndex: Int
    ) -> (index: Int, match: Match)? {
        let upperBound = min(provider.count, providerIndex + maximumProviderLookahead)
        for index in providerIndex..<upperBound {
            if let match = match(source: source, at: sourceIndex, provider: provider, at: index) {
                return (index, match)
            }
        }
        return nil
    }

    private static func match(
        source: [SourceToken],
        at sourceIndex: Int,
        provider: [ProviderToken],
        at providerIndex: Int
    ) -> Match? {
        if source[sourceIndex].canonical == provider[providerIndex].canonical {
            return Match(sourceCount: 1, providerCount: 1)
        }

        let maximumSourceCount = min(maximumCompoundLength, source.count - sourceIndex)
        let maximumProviderCount = min(maximumCompoundLength, provider.count - providerIndex)
        var best: Match?
        for sourceCount in 1...maximumSourceCount {
            let sourceSlice = source[sourceIndex..<(sourceIndex + sourceCount)]
            let sourceCanonical = sourceSlice.map(\.canonical).joined()
            let ignoresNumberConnector = sourceSlice.contains { $0.isNumeric }
            for providerCount in 1...maximumProviderCount {
                guard sourceCount > 1 || providerCount > 1 else { continue }
                let providerCanonical = provider[providerIndex..<(providerIndex + providerCount)]
                    .lazy
                    .map(\.canonical)
                    .filter { !ignoresNumberConnector || $0 != "and" }
                    .reduce(into: "") { $0 += $1 }
                guard sourceCanonical == providerCanonical else { continue }
                let candidate = Match(sourceCount: sourceCount, providerCount: providerCount)
                if let best, best.sourceCount + best.providerCount <= sourceCount + providerCount {
                    continue
                }
                best = candidate
            }
        }
        return best
    }

    private static func apply(
        _ match: Match,
        sourceIndex: Int,
        providerIndex: Int,
        provider: [ProviderToken],
        result: inout [TranscriptAlignedTiming?]
    ) {
        let timing = TranscriptAlignedTiming(
            startTime: provider[providerIndex].timing.startTime,
            endTime: provider[providerIndex + match.providerCount - 1].timing.endTime
        )
        for index in sourceIndex..<(sourceIndex + match.sourceCount) {
            result[index] = timing
        }
    }

    private static func normalize(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func sourceToken(_ token: String) -> SourceToken {
        let normalized = normalize(token)
        let isNumeric = !normalized.isEmpty && normalized.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
        }
        guard isNumeric, let value = Int64(normalized) else {
            return SourceToken(canonical: normalized, isNumeric: false)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        let spoken = formatter.string(from: NSNumber(value: value)).map(normalize) ?? normalized
        return SourceToken(canonical: spoken, isNumeric: true)
    }

    private static func providerCanonical(_ token: String) -> String {
        var canonical = normalize(token)
        // Kokoro can attach the spoken hyphen marker to a technical compound,
        // for example `all-kind-1` becomes `all-kindminus`, `one`.
        if canonical != "minus", canonical.hasSuffix("minus") {
            canonical.removeLast("minus".count)
        }
        return canonical
    }
}
