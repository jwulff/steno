import Testing
@testable import StenoDaemon

/// Tests for resolving a client-supplied `device` string to a concrete
/// Core Audio input device.
///
/// The daemon protocol advertises devices by *name*
/// (`{"cmd":"devices"}` answers `devices.map(\.name)`), so a name is the
/// common input. UIDs are accepted too because they are the stable
/// identifier the engine already tracks internally.
///
/// Resolution is a pure function over a device list so it is testable
/// without Core Audio, a microphone, or TCC grants — none of which exist
/// in CI.
@Suite("AudioInputDeviceResolver Tests")
struct AudioInputDeviceResolverTests {

    private let devices = [
        AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
        AudioInputDevice(id: 77, uid: "8C-DE-52-3F:input", name: "soundcore P30i"),
        AudioInputDevice(id: 92, uid: "com.example.usb:1", name: "Scarlett Solo USB")
    ]

    @Test("Resolves an exact device name")
    func exactName() {
        let match = AudioInputDeviceResolver.resolve("soundcore P30i", in: devices)
        #expect(match?.id == 77)
    }

    @Test("Resolves an exact device UID")
    func exactUID() {
        let match = AudioInputDeviceResolver.resolve("com.example.usb:1", in: devices)
        #expect(match?.id == 92)
    }

    @Test("Resolves a name differing only in case")
    func caseInsensitiveName() {
        let match = AudioInputDeviceResolver.resolve("macbook air microphone", in: devices)
        #expect(match?.id == 41)
    }

    @Test("Returns nil for an unknown device")
    func unknownDevice() {
        #expect(AudioInputDeviceResolver.resolve("Blue Yeti", in: devices) == nil)
    }

    @Test("Returns nil rather than guessing at a partial name")
    func partialNameIsNotAMatch() {
        // Substring matching would silently route to the wrong input,
        // which is exactly the failure mode this change exists to remove.
        #expect(AudioInputDeviceResolver.resolve("MacBook", in: devices) == nil)
    }

    @Test("Returns nil against an empty device list")
    func emptyList() {
        #expect(AudioInputDeviceResolver.resolve("MacBook Air Microphone", in: []) == nil)
    }

    @Test("An exact name wins over another device's UID collision")
    func nameBeatsUIDCollision() {
        let colliding = [
            AudioInputDevice(id: 1, uid: "Studio Mic", name: "Rear Input"),
            AudioInputDevice(id: 2, uid: "uid-2", name: "Studio Mic")
        ]
        let match = AudioInputDeviceResolver.resolve("Studio Mic", in: colliding)
        #expect(match?.id == 2)
    }
}
