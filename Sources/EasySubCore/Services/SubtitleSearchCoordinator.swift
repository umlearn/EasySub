import Foundation

/// Searches at most two sources per video simultaneously; registry order is the tie-breaker,
/// not response timing. Individual source failures do not discard other sources' candidates.
public struct SubtitleSearchCoordinator: Sendable {
    let providers: [any SubtitleProvider]

    public init(provider: any SubtitleProvider) { providers = [provider] }

    public init(providers: [any SubtitleProvider]) throws {
        guard !providers.isEmpty else { throw SubtitleProviderError.emptyRegistry }
        var ids = Set<String>()
        for provider in providers {
            guard ids.insert(provider.source.id).inserted else {
                throw SubtitleProviderError.duplicateSource(provider.source.id)
            }
        }
        self.providers = providers
    }

    public func search(_ request: SubtitleSearchRequest) async throws -> SubtitleSearchResult {
        try Task.checkCancellation()
        let responses = try await withThrowingTaskGroup(of: SearchResponse.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let provider = providers[index]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let candidates = try await provider.search(request)
                        try Task.checkCancellation()
                        guard candidates.allSatisfy({ $0.source == provider.source }) else {
                            throw SubtitleProviderError.invalidCandidate
                        }
                        return SearchResponse(index: index, candidates: candidates, failure: nil)
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        return SearchResponse(index: index, candidates: [],
                                              failure: SubtitleSourceFailure(source: provider.source, error: error))
                    }
                }
            }
            while next < min(2, providers.count) { enqueue(next); next += 1 }
            var results: [SearchResponse] = []
            while let response = try await group.next() {
                try Task.checkCancellation()
                results.append(response)
                if next < providers.count { enqueue(next); next += 1 }
            }
            return results.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        var seen = Set<SubtitleCandidate.ID>()
        let candidates = responses.flatMap(\.candidates).filter { seen.insert($0.id).inserted }
        return SubtitleSearchResult(candidates: candidates, failures: responses.compactMap(\.failure))
    }

    func download(_ candidate: SubtitleCandidate) async throws -> Data {
        guard let provider = providers.first(where: { $0.source == candidate.source }) else {
            throw SubtitleProviderError.invalidCandidate
        }
        return try await provider.download(candidate)
    }
}

private struct SearchResponse: Sendable {
    let index: Int
    let candidates: [SubtitleCandidate]
    let failure: SubtitleSourceFailure?
}
