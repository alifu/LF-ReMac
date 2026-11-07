import Foundation
import Network
import RemoteCore

/// What `HostSession` needs from the outside world; `live` in the app, fakes in tests.
struct HostEnvironment: Sendable {
    static let pairedDevicesService = "com.alifu.lfremac.host.paired-devices"
    static let pairedDevicesKey = "paired-devices"
    static let keepAwakeKey = "keepMacAwake"
    static let allowTailscaleKey = "allowTailscale"
    /// Last streamed display, remembered per paired iPhone: `selectedDisplay.<fingerprint hex>`.
    static func selectedDisplayKey(for fingerprint: DeviceFingerprint) -> String {
        "selectedDisplay.\(fingerprint)"
    }

    /// Loads (or creates on first run) this Mac's TLS identity.
    let loadIdentity: @Sendable (_ deviceName: String) throws -> DeviceIdentity
    let keyStore: any KeyStore
    let displayName: @Sendable () -> String
    /// Address put into the QR code; nil if the Mac has no usable local host name.
    let invitationHost: @Sendable () -> String?
    let serviceType: String?
    let port: NWEndpoint.Port
    let clock: PairingCoordinator.Clock
    let limits: StreamServerLimits
    /// Defaults are inert (in-memory settings, no power assertion) so tests never touch the system.
    var settings: any HostSettings = MemorySettings()
    var acquirePowerAssertion: PowerManager.Acquire = { _ in nil }
    /// Wakes a sleeping display / keeps it on while an iPhone is connected. Inert by default.
    var wakeDisplay: DisplayWaker.Wake = { _ in false }
    var holdDisplay: DisplayWaker.Hold = { _ in nil }
    /// Current displays. Empty by default so tests never touch real screens (the pipeline then uses the main display).
    var displays: @Sendable () -> [DisplayDescriptor] = { [] }
    /// Hardware addresses reported for Wake-on-LAN. Empty by default so tests never read the real network.
    var wakeMACs: @Sendable () -> [String] = { [] }

    static let live = HostEnvironment(
        loadIdentity: { name in try DeviceIdentity.loadOrCreate(deviceName: name) },
        keyStore: KeychainKeyStore(service: pairedDevicesService),
        displayName: { HostNames.displayName() },
        invitationHost: { HostNames.invitationHost() },
        serviceType: StreamServer.bonjourServiceType,
        port: StreamServer.defaultPort,
        clock: { Date() },
        limits: .standard,
        settings: UserDefaults.standard,
        acquirePowerAssertion: PowerManager.systemAcquire,
        wakeDisplay: DisplayWaker.systemWake,
        holdDisplay: DisplayWaker.systemHold,
        displays: { SystemDisplays.current() },
        wakeMACs: { HardwareAddresses.current() }
    )
}

/// Small user preferences; `UserDefaults` in the app, a dictionary in tests.
protocol HostSettings: Sendable {
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

extension UserDefaults: HostSettings {
    func bool(forKey key: String) -> Bool? { object(forKey: key) as? Bool }
    func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func set(_ value: String?, forKey key: String) { set(value as Any?, forKey: key) }
}

/// The Mac's "Pair New iPhone" window state for the UI.
enum PairingState: Equatable {
    case idle
    /// Show `invitation.urlString` as QR and `invitation.secret.displayCode` as text until `expiresAt`.
    case open(PairingInvitation, expiresAt: Date)
    case paired(deviceName: String)
    case failed(String)
}

extension PairingRejection {
    /// Text for the pairing window. Deliberately says nothing about how close a guess was.
    var userMessage: String {
        switch self {
        case .attempt(.invalidProof):
            "A device tried to pair with a wrong code."
        case .attempt(.invalidRequest), .malformedRequest:
            "A device sent an invalid pairing request."
        case .attempt(.expired):
            "The pairing code expired. Start again."
        case .attempt(.tooManyAttempts):
            "Too many wrong attempts. Start again for a new code."
        case .attempt(.notActive):
            "Pairing is not open."
        case .couldNotSave:
            "The iPhone could not be saved. Start again."
        case .timedOut:
            "A device connected but did not finish pairing."
        }
    }
}

/// In-memory settings for tests and previews.
final class MemorySettings: HostSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    private var strings: [String: String] = [:]

    func bool(forKey key: String) -> Bool? { lock.withLock { values[key] } }
    func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
    func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    func set(_ value: String?, forKey key: String) { lock.withLock { strings[key] = value } }
}
