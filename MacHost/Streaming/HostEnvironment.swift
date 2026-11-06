import Foundation
import Network
import RemoteCore

/// What `HostSession` needs from the outside world; `live` in the app, fakes in tests.
struct HostEnvironment: Sendable {
    static let pairedDevicesService = "com.alifu.lfremac.host.paired-devices"
    static let pairedDevicesKey = "paired-devices"

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

    static let live = HostEnvironment(
        loadIdentity: { name in try DeviceIdentity.loadOrCreate(deviceName: name) },
        keyStore: KeychainKeyStore(service: pairedDevicesService),
        displayName: { HostNames.displayName() },
        invitationHost: { HostNames.invitationHost() },
        serviceType: StreamServer.bonjourServiceType,
        port: StreamServer.defaultPort,
        clock: { Date() },
        limits: .standard
    )
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
