import AVFoundation
import CoreAudio
import CoreGraphics

/// Errors specific to system audio capture.
public enum SystemAudioError: Error, Equatable {
    case tapCreationFailed(OSStatus)
    case formatReadFailed(OSStatus)
    case outputDeviceFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case permissionDenied
}

/// Captures system audio using Core Audio Taps API (macOS 14.4+).
///
/// Taps all system audio except Steno's own process. No virtual audio driver required.
/// Conforms to `AudioSource` for use alongside the microphone recognizer.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let name = "System Audio"
    public let sourceType: AudioSourceType = .systemAudio

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tapFormat: AVAudioFormat?

    private let queue = DispatchQueue(label: "com.steno.system-audio-tap", qos: .userInteractive)

    public init() {}

    /// Check if screen/audio capture permission is granted. Core Audio taps
    /// require the "Screen & System Audio Recording" TCC permission.
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen/audio capture permission. Returns true if granted.
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        // 0. Check permission before attempting tap creation
        if !Self.hasPermission() {
            // Request permission — this triggers the system dialog on first call
            Self.requestPermission()
            // After requesting, check again
            if !Self.hasPermission() {
                throw SystemAudioError.permissionDenied
            }
        }

        // 1. Create tap description for all system audio (excluding own process)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessAudioObjectID()])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        // 2. Create process tap
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            // Check if it's a permission issue (common error codes for TCC denial)
            if status == -50 || status == -10 {
                throw SystemAudioError.permissionDenied
            }
            throw SystemAudioError.tapCreationFailed(status)
        }

        // 3. Read tap format
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        var streamDesc = AudioStreamBasicDescription()

        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &streamDesc)
        guard status == noErr else {
            cleanup()
            throw SystemAudioError.formatReadFailed(status)
        }

        guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
            cleanup()
            throw SystemAudioError.formatReadFailed(-1)
        }
        self.tapFormat = format

        // 4. Get system output device UID
        let outputUID = try getDefaultOutputDeviceUID()

        // 5. Create aggregate device with tap
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Steno-SystemAudio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            cleanup()
            throw SystemAudioError.aggregateDeviceFailed(status)
        }

        // 6. Create async stream for buffer delivery
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        // 7. Set up IOProc to receive audio
        let capturedFormat = format
        let capturedContinuation = continuation
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            queue
        ) { _, inInputData, _, _, _ in
            let srcBufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            guard srcBufferList.count > 0, srcBufferList[0].mDataByteSize > 0 else { return }

            // Calculate frame count based on format layout
            let frameCount: AVAudioFrameCount
            if capturedFormat.isInterleaved {
                // Interleaved: single buffer with all channels interleaved
                frameCount = AVAudioFrameCount(srcBufferList[0].mDataByteSize)
                    / AVAudioFrameCount(MemoryLayout<Float>.stride * Int(capturedFormat.channelCount))
            } else {
                // Non-interleaved: each buffer contains one channel's data
                frameCount = AVAudioFrameCount(srcBufferList[0].mDataByteSize)
                    / AVAudioFrameCount(MemoryLayout<Float>.stride)
            }
            guard frameCount > 0 else { return }

            // CRITICAL: Copy the audio data. The IOProc buffer is only valid during this callback.
            guard let copiedBuffer = AVAudioPCMBuffer(
                pcmFormat: capturedFormat,
                frameCapacity: frameCount
            ) else { return }
            copiedBuffer.frameLength = frameCount

            // Copy raw audio data from all IOProc buffers into our new buffer
            let dstBufferList = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
            for i in 0..<min(dstBufferList.count, srcBufferList.count) {
                guard let srcData = srcBufferList[i].mData,
                      let dstData = dstBufferList[i].mData else { continue }
                let byteCount = min(
                    Int(srcBufferList[i].mDataByteSize),
                    Int(dstBufferList[i].mDataByteSize)
                )
                memcpy(dstData, srcData, byteCount)
            }

            nonisolated(unsafe) let unsafeBuffer = copiedBuffer
            capturedContinuation.yield(unsafeBuffer)
        }

        guard status == noErr else {
            cleanup()
            throw SystemAudioError.ioProcFailed(status)
        }

        // 8. Start the device
        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw SystemAudioError.deviceStartFailed(status)
        }

        return (buffers: stream, format: format)
    }

    public func stop() async {
        cleanup()
    }

    // MARK: - Private

    private func cleanup() {
        // Reverse order: stop -> IOProc -> aggregate -> tap
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, ioProcID)

            if let ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }

            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        continuation?.finish()
        continuation = nil
    }

    /// Get the AudioObjectID for our own process so we can exclude it from the tap.
    private func ownProcessAudioObjectID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyTranslatePIDToProcessObject),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var processObject: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.stride),
            &pid,
            &size,
            &processObject
        )

        guard status == noErr, processObject != kAudioObjectUnknown else {
            // Fallback: return unknown, which means we won't exclude ourselves
            // (minor issue - we'd hear our own sounds if any)
            return AudioObjectID(kAudioObjectUnknown)
        }

        return processObject
    }

    /// Get the UID string of the default output device (where apps like Chrome play audio).
    private func getDefaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var outputID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &outputID
        )
        guard status == noErr else {
            throw SystemAudioError.outputDeviceFailed(status)
        }

        // Read the UID
        address.mSelector = AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID)
        size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString

        status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(outputID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw SystemAudioError.outputDeviceFailed(status)
        }

        return uid as String
    }

    deinit {
        cleanup()
    }
}
