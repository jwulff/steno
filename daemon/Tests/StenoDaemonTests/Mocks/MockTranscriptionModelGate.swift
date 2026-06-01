import Foundation
@testable import StenoDaemon

/// Mock Layer-A gate (#62) — returns a configured outcome and records the
/// locales it was asked to prepare, so tests can drive the ready / unavailable
/// branches without touching real hardware or the Speech framework.
actor MockTranscriptionModelGate: TranscriptionModelGate {
    private let outcome: TranscriptionGateOutcome
    private(set) var preparedLocales: [Locale] = []

    init(outcome: TranscriptionGateOutcome) {
        self.outcome = outcome
    }

    func prepare(locale: Locale) async -> TranscriptionGateOutcome {
        preparedLocales.append(locale)
        return outcome
    }

    var prepareCallCount: Int { preparedLocales.count }
}
