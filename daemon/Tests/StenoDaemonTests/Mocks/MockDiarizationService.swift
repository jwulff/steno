import Foundation
@testable import StenoDaemon

/// Test double for `DiarizationService`. Records calls and returns a canned
/// result (or throws). Mirrors the codebase's `@unchecked Sendable` mock style
/// (mutable config touched serially by tests).
final class MockDiarizationService: DiarizationService, @unchecked Sendable {
    struct Call: Equatable {
        let sampleCount: Int
        let sampleRate: Double
        let model: DiarizationModel
    }

    /// Calls recorded in invocation order.
    private(set) var calls: [Call] = []

    /// Returned from `diarize` when `errorToThrow` is nil.
    var resultToReturn = DiarizationResult(
        segments: [],
        embeddings: [],
        modelId: "mock",
        modelVersion: "0"
    )

    /// When set, `diarize` throws this instead of returning a result.
    var errorToThrow: Error?

    /// When set, `prepareModels` throws this (#62 — drives the diarization
    /// model-unavailable branch). Nil → preparation succeeds.
    var prepareError: Error?

    /// Number of times `prepareModels` was invoked.
    private(set) var prepareCallCount = 0

    func prepareModels() async throws {
        prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
    }

    func diarize(
        samples: [Float],
        sampleRate: Double,
        model: DiarizationModel
    ) async throws -> DiarizationResult {
        calls.append(
            Call(sampleCount: samples.count, sampleRate: sampleRate, model: model)
        )
        if let errorToThrow {
            throw errorToThrow
        }
        return resultToReturn
    }
}
