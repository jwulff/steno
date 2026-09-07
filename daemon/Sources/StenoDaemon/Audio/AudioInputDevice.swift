import CoreAudio
import Foundation

/// A Core Audio device that exposes at least one input channel.
///
/// Distinct from `AudioDevice`, which is the wire-facing model the
/// `devices` command answers with. This one carries the `AudioDeviceID`
/// needed to actually route `AVAudioEngine`'s input node, which never
/// leaves the daemon.
public struct AudioInputDevice: Sendable, Equatable {
    /// Core Audio's per-boot handle. Not stable across reboots or
    /// reconnects, so it is resolved fresh at every bring-up.
    public let id: AudioDeviceID
    /// Stable identifier, and what the engine compares across sleep/wake.
    public let uid: String
    /// What the user sees, and what the `devices` command advertises.
    public let name: String

    public init(id: AudioDeviceID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

/// Source of the machine's current input devices.
///
/// Injected so the resolution path is testable: Core Audio enumeration
/// needs real hardware, which CI does not have.
public protocol AudioInputDeviceEnumerating: Sendable {
    /// Every device with one or more input channels, in Core Audio order.
    func inputDevices() -> [AudioInputDevice]

    /// UID of the current default input device, or `nil` if the HAL
    /// cannot resolve one.
    func defaultInputUID() -> String?
}

/// Maps a client-supplied `device` string onto a concrete input device.
///
/// The daemon protocol advertises devices by name — `{"cmd":"devices"}`
/// answers with `devices.map(\.name)` — so a name is what clients have to
/// work with. UIDs are accepted as well because they are the stable
/// identifier and survive a rename.
///
/// Matching is deliberately exact. Substring or prefix matching would
/// silently route capture to a device the caller did not ask for, which
/// is the class of failure this resolution path exists to eliminate.
public enum AudioInputDeviceResolver {

    /// - Returns: The matching device, or `nil` when nothing matches.
    ///   Callers are expected to treat `nil` as a hard failure rather
    ///   than falling back to the system default.
    public static func resolve(
        _ requested: String,
        in devices: [AudioInputDevice]
    ) -> AudioInputDevice? {
        // Name before UID: a name is what the protocol hands out, so on
        // the vanishingly rare collision the caller meant the name.
        if let match = devices.first(where: { $0.name == requested }) { return match }
        if let match = devices.first(where: { $0.uid == requested }) { return match }

        let lowered = requested.lowercased()
        if let match = devices.first(where: { $0.name.lowercased() == lowered }) { return match }
        return devices.first(where: { $0.uid.lowercased() == lowered })
    }
}
