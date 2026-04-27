import Testing
import AVFoundation
import ScreenCaptureKit
@testable import StenoDaemon

@Suite("SystemAudioSource Tests")
struct SystemAudioSourceTests {

    @Test func hasCorrectProperties() {
        let source = SystemAudioSource()

        #expect(source.name == "System Audio")
        #expect(source.sourceType == .systemAudio)
    }

    @Test func conformsToAudioSourceProtocol() {
        let source: any AudioSource = SystemAudioSource()

        #expect(source.sourceType == .systemAudio)
    }

    @Test func systemAudioErrorEquality() {
        #expect(SystemAudioError.permissionDenied == SystemAudioError.permissionDenied)
        #expect(SystemAudioError.noDisplaysAvailable == SystemAudioError.noDisplaysAvailable)
        #expect(SystemAudioError.streamStartFailed("a") == SystemAudioError.streamStartFailed("a"))
        #expect(SystemAudioError.streamStartFailed("a") != SystemAudioError.streamStartFailed("b"))
    }

    @Test func systemAudioErrorTypes() {
        // Verify all error cases exist and are distinguishable
        let errors: [SystemAudioError] = [
            .noDisplaysAvailable,
            .streamStartFailed("test"),
            .permissionDenied,
        ]

        #expect(errors.count == 3)
    }

    // MARK: - Protocol Contract Tests (using MockAudioSource)

    @Test func protocolStartReturnsFormatAndBuffers() async throws {
        let mock = MockAudioSource(name: "System Audio", sourceType: .systemAudio)
        let source: any AudioSource = mock

        let (buffers, format) = try await source.start()

        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)

        await source.stop()
        _ = buffers
    }

    @Test func protocolStopIsIdempotent() async throws {
        let mock = MockAudioSource()
        _ = try await mock.start()

        await mock.stop()
        await mock.stop()  // Second stop should not crash

        #expect(mock.stopCalled)
    }

    @Test func protocolStartErrorPropagates() async {
        let mock = MockAudioSource()
        mock.errorToThrow = SystemAudioError.permissionDenied

        await #expect(throws: SystemAudioError.self) {
            _ = try await mock.start()
        }
    }

    // NOTE: Integration tests for actual hardware (real ScreenCaptureKit, audio capture)
    // are run manually, not in CI. ScreenCaptureKit requires a display and user permission.
}

// MARK: - U8 SCStream Error Classifier Tests

@Suite("SystemAudioErrorClassifier (U8)")
struct SystemAudioErrorClassifierTests {

    private static func makeSCError(_ rawCode: Int) -> NSError {
        NSError(
            domain: SystemAudioErrorClassifier.scStreamErrorDomain,
            code: rawCode,
            userInfo: [NSLocalizedDescriptionKey: "synthetic SCStream error \(rawCode)"]
        )
    }

    @Test("userDeclined (-3801) → .permissionRevoked")
    func userDeclinedClassifiesAsPermissionRevoked() {
        let err = Self.makeSCError(SCStreamError.userDeclined.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .permissionRevoked)
        #expect(err.code == -3801)
    }

    @Test("attemptToStopStreamState (-3808) → .ignore")
    func attemptToStopStreamStateClassifiesAsIgnore() {
        let err = Self.makeSCError(SCStreamError.attemptToStopStreamState.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .ignore)
        #expect(err.code == -3808)
    }

    @Test("systemStoppedStream (-3821) → .retry")
    func systemStoppedStreamClassifiesAsRetry() {
        let err = Self.makeSCError(SCStreamError.systemStoppedStream.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
        #expect(err.code == -3821)
    }

    @Test("failedApplicationConnectionInterrupted (-3805) → .retry")
    func connectionInterruptedClassifiesAsRetry() {
        let err = Self.makeSCError(SCStreamError.failedApplicationConnectionInterrupted.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
        #expect(err.code == -3805)
    }

    @Test("failedApplicationConnectionInvalid (-3804) → .retry")
    func connectionInvalidClassifiesAsRetry() {
        let err = Self.makeSCError(SCStreamError.failedApplicationConnectionInvalid.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
        #expect(err.code == -3804)
    }

    @Test("noCaptureSource (-3815) → .retry")
    func noCaptureSourceClassifiesAsRetry() {
        let err = Self.makeSCError(SCStreamError.noCaptureSource.rawValue)
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
        #expect(err.code == -3815)
    }

    @Test("Unknown SCStream code → .retry")
    func unknownCodeClassifiesAsRetry() {
        // -3899 is not a documented SCStreamError value; classifier
        // must still return .retry so the bounded-backoff loop owns
        // the surrender decision.
        let err = Self.makeSCError(-3899)
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
    }

    @Test("Non-SCStream domain → .retry (defensive)")
    func nonSCStreamDomainClassifiesAsRetry() {
        let err = NSError(domain: "SomeOtherDomain", code: -3801, userInfo: nil)
        // Even though the integer code matches `userDeclined`, the
        // domain does not match — defensive .retry, never permission.
        #expect(SystemAudioErrorClassifier.classify(err) == .retry)
    }

    @Test("backoffKey produces stable domain#code string")
    func backoffKeyProducesStableString() {
        let err = Self.makeSCError(SCStreamError.systemStoppedStream.rawValue)
        let key = SystemAudioErrorClassifier.backoffKey(for: err)
        #expect(key == "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821")
    }

    @Test("backoffKey distinguishes between SCStream codes")
    func backoffKeyDifferentiatesCodes() {
        let a = Self.makeSCError(SCStreamError.systemStoppedStream.rawValue)
        let b = Self.makeSCError(SCStreamError.failedApplicationConnectionInterrupted.rawValue)
        #expect(SystemAudioErrorClassifier.backoffKey(for: a)
                != SystemAudioErrorClassifier.backoffKey(for: b))
    }
}

// MARK: - U8 Microphone Permission Detector Tests

@Suite("MicrophonePermissionErrorDetector (U8)")
struct MicrophonePermissionErrorDetectorTests {

    @Test("kAudioServicesNoSuchHardware OSStatus → permission revocation")
    func noSuchHardwareOSStatusDetected() {
        // 'nope' four-char-code = 0x6E6F7065 = 1852796517
        let err = NSError(domain: "NSOSStatusErrorDomain", code: 1_852_796_517, userInfo: nil)
        #expect(MicrophonePermissionErrorDetector.isPermissionRevocation(err))
    }

    @Test("Description containing 'permission denied' → revocation")
    func descriptionWithPermissionDeniedDetected() {
        let err = NSError(
            domain: "AVFoundationErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
        )
        #expect(MicrophonePermissionErrorDetector.isPermissionRevocation(err))
    }

    @Test("Description containing 'not authorized' → revocation")
    func descriptionWithNotAuthorizedDetected() {
        let err = NSError(
            domain: "AVFoundationErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Recording is not authorized"]
        )
        #expect(MicrophonePermissionErrorDetector.isPermissionRevocation(err))
    }

    @Test("Generic recognizer error does NOT match")
    func genericRecognizerErrorIsNotRevocation() {
        // Mirrors the existing U5 test pattern (`RecogTest#42`).
        let err = NSError(
            domain: "RecogTest",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "RecogTest#42"]
        )
        #expect(!MicrophonePermissionErrorDetector.isPermissionRevocation(err))
    }

    @Test("Generic 'connection lost' error does NOT match")
    func genericConnectionLostIsNotRevocation() {
        let err = NSError(
            domain: "AVFoundationErrorDomain",
            code: -10000,
            userInfo: [NSLocalizedDescriptionKey: "audio engine connection lost"]
        )
        #expect(!MicrophonePermissionErrorDetector.isPermissionRevocation(err))
    }
}

// MARK: - U8 SCStreamDelegate dispatch tests

/// Records the recovery-delegate calls a `SystemAudioSource` makes when
/// its SCStreamDelegate callback fires. Decouples the test from
/// `RecordingEngine` so we can directly assert the dispatch table.
///
/// Implemented as an `actor` so the `async` protocol methods are safely
/// serialized without an `NSLock` (which is unavailable from async
/// contexts under strict concurrency).
actor RecordingRecoveryDelegate: SystemAudioRecoveryDelegate {
    struct RetryCall: Sendable, Equatable {
        let errorCode: String
        let reason: String
    }

    private(set) var retryCalls: [RetryCall] = []
    private(set) var permissionRevokedCount: Int = 0

    nonisolated func systemAudioRequestsRetry(errorCode: String, reason: String) async {
        await appendRetry(RetryCall(errorCode: errorCode, reason: reason))
    }

    nonisolated func systemAudioPermissionRevoked() async {
        await incrementPermissionRevoked()
    }

    private func appendRetry(_ call: RetryCall) {
        retryCalls.append(call)
    }

    private func incrementPermissionRevoked() {
        permissionRevokedCount += 1
    }
}

@Suite("SystemAudioSource SCStreamDelegate Dispatch (U8)")
struct SystemAudioSourceDelegateDispatchTests {

    /// Build a synthetic SCStream we can pass into the delegate
    /// callback. We never start it — the delegate is invoked
    /// directly. SCStream construction does not require Screen
    /// Recording permission; only `startCapture` does.
    private func makeFakeStream() -> SCStream? {
        // Building an SCStream needs a content filter. We use a
        // dummy filter against a fake display list — but
        // `SCContentFilter(display:exceptingApplications:exceptingWindows:)`
        // requires a real `SCDisplay`. We can't synthesize one in
        // tests without Screen Recording permission. Instead we
        // pass the source's `stream(_:didStopWithError:)` a `nil`
        // stream value via Swift's runtime — but the API requires
        // non-nil. Workaround: skip actual SCStream creation by
        // using `unsafeBitCast` from a placeholder. **This is a
        // test-only hack** to invoke the delegate method without a
        // real ScreenCaptureKit session; the SystemAudioSource
        // implementation never reads the `stream` parameter beyond
        // the SCStreamDelegate signature requirement.
        //
        // We can avoid this entirely: the delegate method takes the
        // stream as a parameter but our implementation does NOT use
        // it (only `error` is consumed). So we pass an "empty" SCStream
        // we acquire by reflection — but the cleaner path is to
        // assert behavior at the classifier seam (already covered)
        // and the delegate seam without the stream argument. We
        // therefore exercise the delegate via a tiny helper exposed
        // for tests below.
        return nil
    }

    private static func makeSCError(_ rawCode: Int) -> NSError {
        NSError(
            domain: SystemAudioErrorClassifier.scStreamErrorDomain,
            code: rawCode,
            userInfo: [NSLocalizedDescriptionKey: "synthetic SCStream error \(rawCode)"]
        )
    }

    @Test("retry-class error → delegate.systemAudioRequestsRetry with domain#code key")
    func retryDispatch() async throws {
        let source = SystemAudioSource()
        let recovery = RecordingRecoveryDelegate()
        source.recoveryDelegate = recovery

        let err = Self.makeSCError(SCStreamError.systemStoppedStream.rawValue)
        // Invoke the delegate seam directly. Mirrors what
        // SCStream's internal queue would do on stream stop.
        source.handleStreamStopForTesting(error: err)

        // The dispatch is async (Task-based). Poll briefly.
        let landed = await waitFor(timeout: .seconds(1)) {
            await recovery.retryCalls.count == 1
        }
        #expect(landed)
        let calls = await recovery.retryCalls
        let call = calls.first
        #expect(call?.errorCode == "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821")
        #expect(call?.reason.contains("scstream:") == true)
        let revoked = await recovery.permissionRevokedCount
        #expect(revoked == 0)
    }

    @Test("connectionInterrupted (-3805) retry path")
    func retryDispatchConnectionInterrupted() async throws {
        let source = SystemAudioSource()
        let recovery = RecordingRecoveryDelegate()
        source.recoveryDelegate = recovery

        let err = Self.makeSCError(SCStreamError.failedApplicationConnectionInterrupted.rawValue)
        source.handleStreamStopForTesting(error: err)

        let landed = await waitFor(timeout: .seconds(1)) {
            await recovery.retryCalls.count == 1
        }
        #expect(landed)
        let calls = await recovery.retryCalls
        let call = calls.first
        #expect(call?.errorCode == "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3805")
    }

    @Test("attemptToStopStreamState (-3808) → ignored, no delegate calls")
    func ignoreDispatch() async throws {
        let source = SystemAudioSource()
        let recovery = RecordingRecoveryDelegate()
        source.recoveryDelegate = recovery

        let err = Self.makeSCError(SCStreamError.attemptToStopStreamState.rawValue)
        source.handleStreamStopForTesting(error: err)

        // Give the (non-existent) Task a chance to land if we were
        // wrong about the dispatch path — then assert we observed
        // nothing.
        try await Task.sleep(for: .milliseconds(50))
        let calls = await recovery.retryCalls
        let revoked = await recovery.permissionRevokedCount
        #expect(calls.isEmpty)
        #expect(revoked == 0)
    }

    @Test("userDeclined (-3801) → permissionRevoked, no retry")
    func permissionRevokedDispatch() async throws {
        let source = SystemAudioSource()
        let recovery = RecordingRecoveryDelegate()
        source.recoveryDelegate = recovery

        let err = Self.makeSCError(SCStreamError.userDeclined.rawValue)
        source.handleStreamStopForTesting(error: err)

        let landed = await waitFor(timeout: .seconds(1)) {
            await recovery.permissionRevokedCount == 1
        }
        #expect(landed)
        let calls = await recovery.retryCalls
        #expect(calls.isEmpty)
    }

    // MARK: - SCStream weak-output gotcha

    @Test("Stream output handler is held as a stored property")
    func streamOutputIsStored() {
        // Reflective verification: SystemAudioSource declares a
        // `streamOutput` property of type `StreamOutputHandler?`
        // that is updated by `start()` and cleared by `stop()` /
        // `cleanup()`. Without a stored property the SCStream weak
        // output reference would silently nil out and audio would
        // stop flowing.
        let source = SystemAudioSource()
        let mirror = Mirror(reflecting: source)
        let labels = mirror.children.compactMap { $0.label }
        #expect(labels.contains("streamOutput"),
                "SystemAudioSource must hold streamOutput as a stored property (SCStream weak-reference gotcha)")
    }
}

// MARK: - test helpers (file-private)

/// Polling helper: waits for a predicate to become true within
/// `timeout`, polling every `step`. Mirrors the U5 PipelineRestartTests
/// helper but lives in this file so we don't introduce cross-file
/// helper coupling.
@Sendable
private func waitFor(
    timeout: Duration,
    step: Duration = .milliseconds(10),
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let deadlineNS = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadlineNS {
        if await predicate() { return true }
        try? await Task.sleep(for: step)
    }
    return false
}
