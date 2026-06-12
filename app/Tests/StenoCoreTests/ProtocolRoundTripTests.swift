import Testing
import Foundation
@testable import StenoCore

struct ProtocolRoundTripTests {

    private func jsonObject(_ command: DaemonCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func subscribeOmitsAllOptionalFields() throws {
        let obj = try jsonObject(.subscribe)
        #expect(obj["cmd"] as? String == "subscribe")
        // Nil optionals must be omitted, not encoded as null.
        #expect(obj.keys.sorted() == ["cmd"])
    }

    @Test func timedPauseEncodesAutoResumeOnly() throws {
        let obj = try jsonObject(.pause(autoResumeSeconds: 1800))
        #expect(obj["cmd"] as? String == "pause")
        #expect(obj["autoResumeSeconds"] as? Double == 1800)
        #expect(obj["indefinite"] == nil)
    }

    @Test func indefinitePauseEncodesIndefiniteFlag() throws {
        let obj = try jsonObject(.pauseIndefinitely)
        #expect(obj["cmd"] as? String == "pause")
        #expect(obj["indefinite"] as? Bool == true)
        #expect(obj["autoResumeSeconds"] == nil)
    }

    @Test func reconfigureEncodesSystemAudio() throws {
        let obj = try jsonObject(.reconfigure(systemAudio: true))
        #expect(obj["cmd"] as? String == "reconfigure")
        #expect(obj["systemAudio"] as? Bool == true)
    }

    @Test func decodesStatusResponse() throws {
        let json = """
        {"ok":true,"status":"recording","recording":true,"sessionId":"abc",
         "device":"Built-in Microphone","systemAudio":false,
         "paused":false,"pausedIndefinitely":false}
        """
        let resp = try JSONDecoder().decode(DaemonResponse.self, from: Data(json.utf8))
        #expect(resp.ok)
        #expect(resp.status == "recording")
        #expect(resp.recording == true)
        #expect(resp.sessionId == "abc")
        #expect(resp.device == "Built-in Microphone")
        #expect(resp.paused == false)
    }

    @Test func decodesSegmentEvent() throws {
        let json = """
        {"event":"segment","text":"hello world","source":"microphone",
         "sequenceNumber":42,"startedAt":1700000000.5,"speakerId":"S-1",
         "sessionId":"sess-1"}
        """
        let e = try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
        #expect(e.event == "segment")
        #expect(e.text == "hello world")
        #expect(e.source == "microphone")
        #expect(e.sequenceNumber == 42)
        #expect(e.startedAt == 1700000000.5)
        #expect(e.speakerId == "S-1")
    }

    @Test func decodesLevelEvent() throws {
        let json = #"{"event":"level","mic":0.75,"sys":0.4}"#
        let e = try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
        #expect(e.event == "level")
        #expect(e.mic == 0.75)
        #expect(e.sys == 0.4)
    }

    @Test func decodesPauseStateEvent() throws {
        let json = """
        {"event":"pause_state","paused":true,"pausedIndefinitely":false,
         "pauseExpiresAt":1700001800.0}
        """
        let e = try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
        #expect(e.event == "pause_state")
        #expect(e.paused == true)
        #expect(e.pauseExpiresAt == 1700001800.0)
    }

    @Test func decodesModelStatusEvent() throws {
        let json = """
        {"event":"model_status","component":"diarization","state":"unavailable",
         "reason":"Clustering unavailable"}
        """
        let e = try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
        #expect(e.component == "diarization")
        #expect(e.state == "unavailable")
        #expect(e.reason == "Clustering unavailable")
    }

    @Test func ignoresSubscribeAckAsEvent() throws {
        // The subscribe ack ({"ok":true}) must NOT decode as an event.
        let json = #"{"ok":true}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
        }
    }
}
