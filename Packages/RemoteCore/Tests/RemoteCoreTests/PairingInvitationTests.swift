import Foundation
import Testing
@testable import RemoteCore

struct PairingInvitationTests {
    private static let secret = Fixtures.secret()
    private static let fp = Fixtures.host.description
    private static let code = secret.compactCode

    private static func url(v: String = "1", h: String = "mac-mini.local", p: String = "47800", f: String = fp, s: String = code) -> String {
        "lfremac://pair?v=\(v)&h=\(h)&p=\(p)&f=\(f)&s=\(s)"
    }

    @Test(arguments: ["mac-mini.local", "192.168.1.20", "100.64.0.7", "fe80::1", "macmini"])
    func roundTripsThroughTheURLString(host: String) throws {
        let invitation = try PairingInvitation(host: host, port: 47800, hostFingerprint: Fixtures.host, secret: Self.secret)

        let parsed = try PairingInvitation(urlString: invitation.urlString)

        #expect(parsed == invitation)
        #expect(invitation.urlString == Self.url(h: host))
    }

    @Test func descriptionDoesNotContainTheSecret() throws {
        let invitation = try PairingInvitation(urlString: Self.url())

        #expect(!"\(invitation)".contains(Self.code))
        #expect("\(invitation)".contains(Self.fp))
    }

    @Test func acceptsFieldsInAnyOrder() throws {
        let reordered = "lfremac://pair?s=\(Self.code)&f=\(Self.fp)&p=47800&h=mac&v=1"

        #expect(try PairingInvitation(urlString: reordered).host == "mac")
    }

    @Test(arguments: [
        ("https://pair?v=1", PairingInvitationError.notAnInvitation),
        ("lfremac://other?v=1", .notAnInvitation),
        ("LFREMAC://pair?v=1", .notAnInvitation),
        ("lfremac://pair?v=1&&h=x", .notAnInvitation),
        ("lfremac://pair?v", .notAnInvitation)
    ])
    func rejectsWrongShape(input: String, error: PairingInvitationError) {
        #expect(throws: error) { try PairingInvitation(urlString: input) }
    }

    @Test func rejectsUnknownVersion() {
        #expect(throws: PairingInvitationError.unsupportedVersion) { try PairingInvitation(urlString: Self.url(v: "2")) }
        #expect(throws: PairingInvitationError.unsupportedVersion) { try PairingInvitation(urlString: Self.url(v: "01")) }
    }

    @Test func rejectsMissingDuplicateAndUnknownFields() {
        let missing = "lfremac://pair?v=1&h=mac&p=1&f=\(Self.fp)"
        let duplicate = Self.url() + "&h=evil"
        let unknown = Self.url() + "&x=1"

        #expect(throws: PairingInvitationError.missingField("s")) { try PairingInvitation(urlString: missing) }
        #expect(throws: PairingInvitationError.duplicateField("h")) { try PairingInvitation(urlString: duplicate) }
        #expect(throws: PairingInvitationError.unknownField) { try PairingInvitation(urlString: unknown) }
    }

    @Test(arguments: ["0", "65536", "-1", "+80", "080", "8o", "", "４７８００", "999999"])
    func rejectsBadPorts(port: String) {
        #expect(throws: PairingInvitationError.invalidPort) { try PairingInvitation(urlString: Self.url(p: port)) }
    }

    @Test(arguments: ["", "mac/../x", "mac mini", "mac%2F", "[fe80::1]", "mäc", "a@b", String(repeating: "a", count: 254)])
    func rejectsBadHosts(host: String) {
        #expect(throws: PairingInvitationError.self) { try PairingInvitation(urlString: Self.url(h: host)) }
    }

    @Test(arguments: ["", "abc", String(repeating: "z", count: 64), String(fp.dropLast()), fp + "0"])
    func rejectsBadFingerprints(fingerprint: String) {
        #expect(throws: PairingInvitationError.invalidFingerprint) { try PairingInvitation(urlString: Self.url(f: fingerprint)) }
    }

    @Test func rejectsNonCanonicalOrMalformedSecrets() {
        let dashed = Self.secret.displayCode
        let lowercase = Self.code.lowercased()
        let short = String(Self.code.dropLast())
        let invalid = String(Self.code.dropLast()) + "U"

        for value in [dashed, lowercase, short, invalid, ""] where value != Self.code {
            #expect(throws: PairingInvitationError.invalidSecret) { try PairingInvitation(urlString: Self.url(s: value)) }
        }
    }

    @Test func rejectsOverlongInput() {
        let long = Self.url() + String(repeating: "A", count: PairingInvitation.maxLength)

        #expect(throws: PairingInvitationError.tooLong) { try PairingInvitation(urlString: long) }
    }

    @Test func initializerValidatesHostAndPort() {
        #expect(throws: PairingInvitationError.invalidHost) {
            try PairingInvitation(host: "a b", port: 1, hostFingerprint: Fixtures.host, secret: Self.secret)
        }
        #expect(throws: PairingInvitationError.invalidPort) {
            try PairingInvitation(host: "mac", port: 0, hostFingerprint: Fixtures.host, secret: Self.secret)
        }
    }
}
