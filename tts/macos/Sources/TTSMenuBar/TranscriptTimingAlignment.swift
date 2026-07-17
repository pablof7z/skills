import Foundation

struct TranscriptAlignedTiming: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptTimingAlignment {
    private struct ProviderToken {
        let normalized: String
        var timing: TranscriptAlignedTiming
    }

    private struct Match {
        let sourceCount: Int
        let providerCount: Int
    }

    private static let maximumCompoundLength = 8

    static func align(
        sourceTokens: [String],
        timings: [TTSWordTiming]?
    ) -> [TranscriptAlignedTiming?] {
        guard !sourceTokens.isEmpty else { return [] }
        let source = sourceTokens.map(normalize)
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
            let normalized = normalize(timing.word)
            if normalized.isEmpty {
                if let last = result.indices.last {
                    result[last].timing = TranscriptAlignedTiming(
                        startTime: result[last].timing.startTime,
                        endTime: max(result[last].timing.endTime, timing.endTime)
                    )
                }
                continue
            }
            result.append(ProviderToken(
                normalized: normalized,
                timing: TranscriptAlignedTiming(
                    startTime: max(0, timing.startTime),
                    endTime: max(timing.startTime, timing.endTime)
                )
            ))
        }
        return result
    }

    private static func alignmentScore(
        source: [String],
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
        source: [String],
        at sourceIndex: Int,
        provider: [ProviderToken],
        startingAt providerIndex: Int
    ) -> (index: Int, match: Match)? {
        for index in providerIndex..<provider.count {
            if let match = match(source: source, at: sourceIndex, provider: provider, at: index) {
                return (index, match)
            }
        }
        return nil
    }

    private static func match(
        source: [String],
        at sourceIndex: Int,
        provider: [ProviderToken],
        at providerIndex: Int
    ) -> Match? {
        let maximumSourceCount = min(maximumCompoundLength, source.count - sourceIndex)
        if maximumSourceCount >= 2 {
            var merged = source[sourceIndex]
            for count in 2...maximumSourceCount {
                merged += source[sourceIndex + count - 1]
                if merged == provider[providerIndex].normalized {
                    return Match(sourceCount: count, providerCount: 1)
                }
            }
        }

        let maximumProviderCount = min(maximumCompoundLength, provider.count - providerIndex)
        if maximumProviderCount >= 2 {
            var merged = provider[providerIndex].normalized
            for count in 2...maximumProviderCount {
                merged += provider[providerIndex + count - 1].normalized
                if source[sourceIndex] == merged {
                    return Match(sourceCount: 1, providerCount: count)
                }
            }
        }

        guard tokensCorrespond(source[sourceIndex], provider[providerIndex].normalized) else {
            return nil
        }
        return Match(sourceCount: 1, providerCount: 1)
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

    private static func tokensCorrespond(_ source: String, _ provider: String) -> Bool {
        guard !source.isEmpty, !provider.isEmpty else { return false }
        if source == provider { return true }
        guard min(source.count, provider.count) >= 3 else { return false }
        return source.contains(provider) || provider.contains(source)
    }
}
