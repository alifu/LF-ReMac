import Foundation
import Testing
@testable import RemoteCore

struct SessionMessageCodingTests {
    private let uuidA = "11111111-2222-3333-4444-555555555555"
    private let uuidB = "66666666-7777-8888-9999-AAAAAAAAAAAA"

    private func display(_ id: String, name: String = "Built-in", width: Int = 3024, height: Int = 1964, main: Bool = true) -> DisplayInfo {
        DisplayInfo(id: id, name: name, pixelWidth: width, pixelHeight: height, isMain: main)
    }

    private func hostInfo(
        displays: [DisplayInfo]? = nil, selected: String? = nil,
        macs: [String] = ["aa:bb:cc:dd:ee:ff"], virtual: Bool = false
    ) -> HostInfo {
        HostInfo(
            displays: displays ?? [display(uuidA)], selectedID: selected ?? uuidA,
            wakeMACs: macs, virtualDisplaySupported: virtual
        )
    }

    // MARK: Wire values

    @Test func newMessageTypesKeepTheirWireValues() {
        #expect(MessageType.clientHello.rawValue == 8)
        #expect(MessageType.hostInfo.rawValue == 9)
        #expect(MessageType.selectDisplay.rawValue == 10)
    }

    // MARK: Round trips

    @Test func clientHelloRoundTrips() throws {
        let hello = ClientHello(protocolVersion: 1, capabilities: [.displays, .audio])

        let frame = try SessionMessageCoding.frame(for: hello, timestampMicros: 5)
        let decoded = try SessionMessageCoding.clientHello(from: frame)

        #expect(frame.type == .clientHello)
        #expect(decoded == hello)
    }

    @Test func hostInfoRoundTrips() throws {
        let info = hostInfo(
            displays: [display(uuidA), display(uuidB, name: "LG", width: 2560, height: 1440, main: false)],
            selected: uuidB, virtual: true
        )

        let frame = try SessionMessageCoding.frame(for: info, timestampMicros: 5)

        #expect(frame.type == .hostInfo)
        #expect(try SessionMessageCoding.hostInfo(from: frame) == info)
    }

    @Test func selectDisplayRoundTrips() throws {
        let selection = SelectDisplay(displayID: uuidB)

        let frame = try SessionMessageCoding.frame(for: selection, timestampMicros: 5)

        #expect(frame.type == .selectDisplay)
        #expect(try SessionMessageCoding.selectDisplay(from: frame) == selection)
    }

    @Test func clientHelloIgnoresCapabilitiesItDoesNotKnow() throws {
        let json = #"{"protocolVersion":2,"capabilities":["displays","holograms"]}"#
        let frame = Frame(type: .clientHello, timestampMicros: 0, payload: Data(json.utf8))

        let hello = try SessionMessageCoding.clientHello(from: frame)

        #expect(hello.capabilities == [.displays])
        #expect(hello.protocolVersion == 2)
    }

    // MARK: Rejections

    @Test func rejectsWrongFrameType() {
        let frame = Frame(type: .ping, timestampMicros: 0, payload: Data("{}".utf8))
        #expect(throws: SessionMessageError.wrongMessageType) { try SessionMessageCoding.clientHello(from: frame) }
    }

    @Test func rejectsOversizedPayloadsBeforeParsing() {
        let big = Data(repeating: 0x20, count: SessionMessageCoding.maxHostInfoBytes + 1)
        let frame = Frame(type: .hostInfo, timestampMicros: 0, payload: big)
        #expect(throws: SessionMessageError.payloadTooLarge(big.count)) { try SessionMessageCoding.hostInfo(from: frame) }

        let smallCap = Data(repeating: 0x20, count: SessionMessageCoding.maxSmallMessageBytes + 1)
        let hello = Frame(type: .clientHello, timestampMicros: 0, payload: smallCap)
        #expect(throws: SessionMessageError.payloadTooLarge(smallCap.count)) { try SessionMessageCoding.clientHello(from: hello) }
    }

    @Test func rejectsMalformedJSON() {
        let frame = Frame(type: .selectDisplay, timestampMicros: 0, payload: Data("nope".utf8))
        #expect(throws: SessionMessageError.malformedPayload) { try SessionMessageCoding.selectDisplay(from: frame) }
    }

    @Test func rejectsNonPositiveOrAbsurdProtocolVersion() throws {
        for version in [0, -1, 1_000] {
            let json = #"{"protocolVersion":\#(version),"capabilities":[]}"#
            let frame = Frame(type: .clientHello, timestampMicros: 0, payload: Data(json.utf8))
            #expect(throws: SessionMessageError.invalidField) { try SessionMessageCoding.clientHello(from: frame) }
        }
    }

    @Test func rejectsSelectDisplayWithBadID() throws {
        for bad in ["", "not-a-uuid", String(repeating: "a", count: 200)] {
            let frame = try SessionMessageCoding.frame(for: SelectDisplay(displayID: bad), timestampMicros: 0)
            #expect(throws: SessionMessageError.invalidField) { try SessionMessageCoding.selectDisplay(from: frame) }
        }
    }

    @Test func rejectsHostInfoWithInvalidContent() throws {
        let cases: [HostInfo] = [
            hostInfo(displays: [display("bad-id")]),
            hostInfo(displays: [display(uuidA, width: 0)]),
            hostInfo(displays: [display(uuidA, height: 20_000)]),
            hostInfo(displays: [display(uuidA, name: String(repeating: "x", count: 65))]),
            hostInfo(displays: [display(uuidA), display(uuidA, main: false)]),
            hostInfo(selected: uuidB),
            hostInfo(macs: ["aa:bb:cc"]),
            hostInfo(macs: ["zz:bb:cc:dd:ee:ff"]),
            hostInfo(macs: Array(repeating: "aa:bb:cc:dd:ee:ff", count: SessionMessageCoding.maxWakeMACs + 1)),
            hostInfo(displays: (0..<(SessionMessageCoding.maxDisplays + 1)).map {
                display(String(format: "00000000-0000-0000-0000-%012d", $0), main: $0 == 0)
            }, selected: "00000000-0000-0000-0000-000000000000"),
        ]
        for info in cases {
            let frame = try SessionMessageCoding.frame(for: info, timestampMicros: 0)
            #expect(throws: SessionMessageError.invalidField) { try SessionMessageCoding.hostInfo(from: frame) }
        }
    }

    @Test func allowsHostInfoWithNoDisplaysAndNoSelection() throws {
        let info = HostInfo(displays: [], selectedID: nil, wakeMACs: [], virtualDisplaySupported: false)
        let frame = try SessionMessageCoding.frame(for: info, timestampMicros: 0)
        #expect(try SessionMessageCoding.hostInfo(from: frame) == info)
    }
}

struct PeerCapabilitiesTests {
    private func info() -> Frame { Frame(type: .hostInfo, timestampMicros: 0, payload: Data()) }

    @Test func peerThatNeverSaidHelloGetsOnlyLegacyTypes() {
        let caps = PeerCapabilities.legacy

        #expect(caps.canReceive(.videoConfig))
        #expect(caps.canReceive(.videoFrame))
        #expect(caps.canReceive(.ping))
        #expect(caps.canReceive(.pairResponse))
        #expect(!caps.canReceive(.hostInfo))
    }

    @Test func hostInfoRequiresTheDisplaysCapability() {
        #expect(PeerCapabilities(hello: ClientHello(protocolVersion: 1, capabilities: [.displays])).canReceive(.hostInfo))
        #expect(!PeerCapabilities(hello: ClientHello(protocolVersion: 1, capabilities: [.audio])).canReceive(.hostInfo))
    }

    @Test func hostNeverSendsClientOnlyTypes() {
        let caps = PeerCapabilities(hello: ClientHello(protocolVersion: 1, capabilities: [.displays, .audio, .virtualDisplay]))

        #expect(!caps.canReceive(.clientHello))
        #expect(!caps.canReceive(.selectDisplay))
        #expect(!caps.canReceive(.keyframeRequest))
        #expect(!caps.canReceive(.input))
    }

    @Test func pairedDecoderAcceptsClientMessagesAndRejectsHostOnes() throws {
        var decoder = FrameDecoder(allowedTypes: ProtocolTypes.hostAcceptsFromPairedClient)
        let hello = try SessionMessageCoding.frame(
            for: ClientHello(protocolVersion: 1, capabilities: [.displays]), timestampMicros: 0)
        #expect(try decoder.append(FrameEncoder.encode(hello)) == [hello])

        var strict = FrameDecoder(allowedTypes: ProtocolTypes.hostAcceptsFromPairedClient)
        let host = Frame(type: .hostInfo, timestampMicros: 0, payload: Data())
        #expect(throws: FrameError.disallowedType(.hostInfo)) { try strict.append(FrameEncoder.encode(host)) }
    }
}
