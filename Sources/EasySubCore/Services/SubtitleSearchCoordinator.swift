import Foundation

/// Searches every source for a video concurrently while a process-wide limiter prevents batches
/// from flooding remote services. Registry order is the tie-breaker, not response timing.
/// Individual source failures do not discard other sources' candidates.
public struct SubtitleSearchCoordinator: Sendable {
    let providers: [any SubtitleProvider]
    private let searchLimiter: SubtitleSearchLimiter

    public init(provider: any SubtitleProvider) {
        providers = [provider]
        searchLimiter = .shared
    }

    public init(providers: [any SubtitleProvider]) throws {
        try self.init(providers: providers, searchLimiter: .shared)
    }

    init(providers: [any SubtitleProvider], searchLimiter: SubtitleSearchLimiter) throws {
        guard !providers.isEmpty else { throw SubtitleProviderError.emptyRegistry }
        var ids = Set<String>()
        for provider in providers {
            guard ids.insert(provider.source.id).inserted else {
                throw SubtitleProviderError.duplicateSource(provider.source.id)
            }
        }
        self.providers = providers
        self.searchLimiter = searchLimiter
    }

    public func search(_ request: SubtitleSearchRequest) async throws -> SubtitleSearchResult {
        try Task.checkCancellation()
        let responses = try await withThrowingTaskGroup(of: SearchResponse.self) { group in
            func enqueue(_ index: Int) {
                let provider = providers[index]
                group.addTask {
                    try await searchLimiter.run {
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
            }
            for index in providers.indices { enqueue(index) }
            var results: [SearchResponse] = []
            while let response = try await group.next() {
                try Task.checkCancellation()
                results.append(response)
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

actor SubtitleSearchLimiter {
    static let shared = SubtitleSearchLimiter(limit: 8)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
        available = limit
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if !acquired { throw CancellationError() }
    }

    private func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

private struct SearchResponse: Sendable {
    let index: Int
    let candidates: [SubtitleCandidate]
    let failure: SubtitleSourceFailure?
}
