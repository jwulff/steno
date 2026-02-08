import Testing
import Foundation
@testable import StenoDaemon

@Suite("DaemonProtocol Tests")
struct DaemonProtocolTests {

    // MARK: - DaemonCommand

    @Test func commandEncodeDecodeRoundTrip() throws {
        let command = DaemonCommand(
            cmd: "start",
            locale: "en_US",
            device: "Built-in Microphone",
            systemAudio: true,
            events: ["partial", "level"]
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DaemonCommand.self, from: data)

        #expect(decoded.cmd == "start")
        #expect(decoded.locale == "en_US")
        #expect(decoded.device == "Built-in Microphone")
        #expect(decoded.systemAudio == true)
        #expect(decoded.events == ["partial", "level"])
    }

    @Test func commandMinimalFields() throws {
        let json = #"{"cmd":"status"}"#
        let data = Data(json.utf8)
        let command = try JSONDecoder().decode(DaemonCommand.self, from: data)

        #expect(command.cmd == "status")
        #expect(command.locale == nil)
        #expect(command.device == nil)
        #expect(command.systemAudio == nil)
        #expect(command.events == nil)
    }

    @Test func commandMalformedJSON() {
        let json = "not json"
        let data = Data(json.utf8)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DaemonCommand.self, from: data)
        }
    }

    @Test func commandMissingRequiredField() {
        let json = #"{"locale":"en_US"}"# // missing cmd
        let data = Data(json.utf8)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DaemonCommand.self, from: data)
        }
    }

    // MARK: - DaemonResponse

    @Test func responseEncodeDecodeRoundTrip() throws {
        let response = DaemonResponse(
            ok: true,
            sessionId: "abc-123",
            recording: true,
            segments: 42,
            devices: ["Mic 1", "Mic 2"]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: data)

        #expect(decoded.ok == true)
        #expect(decoded.sessionId == "abc-123")
        #expect(decoded.recording == true)
        #expect(decoded.segments == 42)
        #expect(decoded.devices == ["Mic 1", "Mic 2"])
    }

    @Test func responseSuccess() throws {
        let response = DaemonResponse.success()
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: data)

        #expect(decoded.ok == true)
        #expect(decoded.error == nil)
    }

    @Test func responseFailure() throws {
        let response = DaemonResponse.failure("something broke")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: data)

        #expect(decoded.ok == false)
        #expect(decoded.error == "something broke")
    }

    // MARK: - DaemonEvent

    @Test func eventEncodeDecodeRoundTrip() throws {
        let event = DaemonEvent(
            event: "partial",
            text: "hello world",
            source: "microphone"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DaemonEvent.self, from: data)

        #expect(decoded.event == "partial")
        #expect(decoded.text == "hello world")
        #expect(decoded.source == "microphone")
    }

    @Test func eventLevelFields() throws {
        let event = DaemonEvent(
            event: "level",
            mic: 0.75,
            sys: 0.3
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DaemonEvent.self, from: data)

        #expect(decoded.event == "level")
        #expect(decoded.mic == 0.75)
        #expect(decoded.sys == 0.3)
    }

    @Test func eventStatusFields() throws {
        let event = DaemonEvent(
            event: "status",
            recording: true,
            modelProcessing: false
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DaemonEvent.self, from: data)

        #expect(decoded.event == "status")
        #expect(decoded.recording == true)
        #expect(decoded.modelProcessing == false)
    }

    @Test func eventErrorFields() throws {
        let event = DaemonEvent(
            event: "error",
            message: "mic disconnected",
            transient: true
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DaemonEvent.self, from: data)

        #expect(decoded.event == "error")
        #expect(decoded.message == "mic disconnected")
        #expect(decoded.transient == true)
    }

    @Test func eventMinimalFields() throws {
        let json = #"{"event":"status"}"#
        let data = Data(json.utf8)
        let event = try JSONDecoder().decode(DaemonEvent.self, from: data)

        #expect(event.event == "status")
        #expect(event.text == nil)
        #expect(event.mic == nil)
    }
}
