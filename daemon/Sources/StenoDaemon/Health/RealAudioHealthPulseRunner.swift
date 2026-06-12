import Foundation

/// Production real-audio pulse: synthesize a fresh phrase with `say(1)`, let it
/// leave the default output device, then poll the normal persisted segment path
/// for the phrase. No in-process audio injection or recognizer test doubles are
/// used here.
public struct RealAudioHealthPulseRunner: HealthPulseRunning {
    private let repository: any TranscriptRepository
    private let permissionService: any PermissionService
    private let timeoutSeconds: Double
    private let pollInterval: Duration
    private let threshold: Double
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String
    private let speaker: @Sendable (String) async throws -> Void
    private let sleeper: @Sendable (Duration) async throws -> Void

    public init(
        repository: any TranscriptRepository,
        permissionService: any PermissionService,
        timeoutSeconds: Double = 45,
        pollInterval: Duration = .seconds(1),
        threshold: Double = 0.82,
        now: @Sendable @escaping () -> Date = { Date() },
        nonce: @Sendable @escaping () -> String = { RealAudioHealthPulseRunner.makeNonce() },
        speaker: @Sendable @escaping (String) async throws -> Void = RealAudioHealthPulseRunner.say,
        sleeper: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.timeoutSeconds = timeoutSeconds
        self.pollInterval = pollInterval
        self.threshold = threshold
        self.now = now
        self.nonce = nonce
        self.speaker = speaker
        self.sleeper = sleeper
    }

    public func run(trigger: HealthPulseTrigger) async -> HealthPulseRunResult {
        let permissions = await permissionService.checkPermissions()
        guard permissions.allGranted else {
            return HealthPulseRunResult(
                state: .cannotRun,
                expectedText: "",
                threshold: threshold,
                message: permissions.errorMessage ?? "Cannot run health pulse: required audio permissions are not granted"
            )
        }

        let token = nonce()
        let phrase = "Steno health pulse token \(token)"
        let started = now()

        do {
            try await speaker(phrase)
        } catch {
            return HealthPulseRunResult(
                state: .cannotRun,
                expectedText: phrase,
                threshold: threshold,
                message: "Cannot run health pulse TTS: \(error.localizedDescription)"
            )
        }

        let deadline = started.addingTimeInterval(timeoutSeconds)
        var bestText = ""
        var bestScore = 0.0

        while now() <= deadline {
            let segments = (try? await repository.segments(from: started.addingTimeInterval(-1), to: now())) ?? []
            let observed = segments.map(\.text).joined(separator: " ")
            let score = Self.similarity(expected: phrase, observed: observed)
            if score > bestScore {
                bestScore = score
                bestText = observed
            }
            if score >= threshold {
                return HealthPulseRunResult(
                    state: .passed,
                    expectedText: phrase,
                    observedText: observed,
                    similarity: score,
                    threshold: threshold,
                    message: "Health pulse passed for trigger \(trigger.rawValue)"
                )
            }
            try? await sleeper(pollInterval)
        }

        return HealthPulseRunResult(
            state: .failed,
            expectedText: phrase,
            observedText: bestText.isEmpty ? nil : bestText,
            similarity: bestScore,
            threshold: threshold,
            message: "Health pulse did not observe the expected token within \(Int(timeoutSeconds))s"
        )
    }

    public static func say(_ phrase: String) async throws {
        final class ResumeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false

            func resumeOnce(
                _ continuation: CheckedContinuation<Void, any Error>,
                with result: Result<Void, any Error>
            ) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [phrase]
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    box.resumeOnce(continuation, with: .success(()))
                } else {
                    box.resumeOnce(continuation, with: .failure(NSError(
                        domain: "StenoHealthPulse",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "say exited with status \(process.terminationStatus)"]
                    )))
                }
            }
            do {
                try process.run()
            } catch {
                box.resumeOnce(continuation, with: .failure(error))
            }
        }
    }

    static func makeNonce() -> String {
        let words = [
            "amber", "bravo", "cedar", "delta", "ember", "fable", "ginger", "harbor",
            "iris", "juno", "kilo", "lemon", "mango", "nova", "onyx", "piper"
        ]
        let value = UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64.random(in: 0...UInt64.max)
        return (0..<4).map { index in
            words[Int((value >> UInt64(index * 4)) & 0xF)]
        }.joined(separator: " ")
    }

    static func similarity(expected: String, observed: String) -> Double {
        let lhs = normalize(expected)
        let rhs = normalize(observed)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if rhs.contains(lhs) { return 1 }
        let distance = levenshtein(lhs, rhs)
        return max(0, 1 - (Double(distance) / Double(max(lhs.count, rhs.count))))
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ac) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, bc) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (ac == bc ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
