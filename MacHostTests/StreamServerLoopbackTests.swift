import Foundation
import Network
import RemoteCore
import Testing
@testable import MacHost

/// Real sockets and real mutual TLS over loopback: a pinned, already-paired `TLSTestClient` plays the iPhone.
@Suite(.serialized)
struct StreamServerLoopbackTests {
    private func withPairedClient(_ body: (ServerHarness, DeviceIdentity, TLSTestClient) async throws -> Void) async throws {
        try await ServerHarness.run(phones: ["Paired Phone"]) { harness, phones in
            let phone = phones[0]
            try harness.pair(phone)
            let client = try harness.connect(phone)
            defer { client.close() }
            try await harness.recorder.waitFor(.clientConnected(phone.fingerprint))
            try await body(harness, phone, client)
        }
    }

    @Test func reportsPairedClientConnectionAndRequestsKeyframe() async throws {
        try await withPairedClient { harness, _, _ in
            try await harness.recorder.waitFor(.keyframeNeeded)
        }
    }

    @Test func deliversConfigKeyframeAndDeltaFramesInOrder() async throws {
        try await withPairedClient { harness, _, client in
            let config = Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1]))
            let key = Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 1, payload: Data([2]))
            let delta = Frame(type: .videoFrame, timestampMicros: 2, payload: Data([3]))
            harness.server.broadcast(delta)  // dropped: client has no keyframe yet
            harness.server.broadcast(config)
            harness.server.broadcast(key)
            harness.server.broadcast(delta)

            let received = try await client.receive(count: 3)

            #expect(received == [config, key, delta])
        }
    }

    @Test func echoesPingWithSamePayload() async throws {
        try await withPairedClient { _, _, client in
            let ping = Frame(type: .ping, timestampMicros: 99, payload: Data([7, 7]))
            client.send(ping)

            let received = try await client.receive(count: 1)

            #expect(received == [ping])
        }
    }

    @Test func keyframeRequestFromClientRaisesKeyframeNeeded() async throws {
        try await withPairedClient { harness, _, client in
            try await harness.recorder.waitFor(.keyframeNeeded)  // the automatic one on connect

            client.send(Frame(type: .keyframeRequest, timestampMicros: 0, payload: Data()))

            try await harness.recorder.waitFor(.keyframeNeeded, count: 2)
        }
    }

    @Test func reportsDisconnectWhenClientCloses() async throws {
        try await withPairedClient { harness, phone, client in
            client.close()

            try await harness.recorder.waitFor(.clientDisconnected(phone.fingerprint))
        }
    }

    @Test func validInputFromClientBecomesInputEvent() async throws {
        try await withPairedClient { harness, _, client in
            let event = InputEvent.button(.left, isDown: true, at: NormalizedPoint(x: 0.3, y: 0.4))
            client.send(try InputEventCoding.frame(for: event, timestampMicros: 1))

            try await harness.recorder.waitFor(.input(event))
        }
    }

    @Test func invalidInputIsDroppedAndConnectionStaysUp() async throws {
        try await withPairedClient { harness, _, client in
            client.send(Frame(type: .input, timestampMicros: 0, payload: Data("not json".utf8)))
            let valid = InputEvent.text("ok")
            client.send(try InputEventCoding.frame(for: valid, timestampMicros: 2))

            try await harness.recorder.waitFor(.input(valid))
            #expect(!client.isClosed)
        }
    }

    // MARK: Phase 7 session messages

    private let displayID = "11111111-2222-3333-4444-555555555555"

    private func sampleHostInfo() -> HostInfo {
        HostInfo(
            displays: [DisplayInfo(id: displayID, name: "Built-in", pixelWidth: 100, pixelHeight: 50, isMain: true)],
            selectedID: displayID, wakeMACs: [], virtualDisplaySupported: false
        )
    }

    @Test func helloBecomesACapabilitiesEvent() async throws {
        try await withPairedClient { harness, _, client in
            let hello = ClientHello(protocolVersion: 1, capabilities: [.displays])
            client.send(try SessionMessageCoding.frame(for: hello, timestampMicros: 0))

            try await harness.recorder.waitFor(.clientHello(PeerCapabilities(hello: hello)))
        }
    }

    @Test func hostInfoReachesAClientThatAskedForDisplays() async throws {
        try await withPairedClient { harness, _, client in
            let hello = ClientHello(protocolVersion: 1, capabilities: [.displays])
            client.send(try SessionMessageCoding.frame(for: hello, timestampMicros: 0))
            try await harness.recorder.waitFor(.clientHello(PeerCapabilities(hello: hello)))

            harness.server.sendHostInfo(sampleHostInfo())

            let received = try await client.receive(count: 1)
            #expect(try SessionMessageCoding.hostInfo(from: received[0]) == sampleHostInfo())
        }
    }

    @Test func hostInfoIsNotSentToAClientThatNeverSaidHello() async throws {
        try await withPairedClient { harness, _, client in
            harness.server.sendHostInfo(sampleHostInfo())
            let ping = Frame(type: .ping, timestampMicros: 1, payload: Data([1]))
            client.send(ping)

            let received = try await client.receive(count: 1)

            #expect(received == [ping])  // the first thing back is the echo, so no hostInfo came before it
        }
    }

    @Test func selectDisplayBecomesAnEvent() async throws {
        try await withPairedClient { harness, _, client in
            client.send(try SessionMessageCoding.frame(for: SelectDisplay(displayID: displayID), timestampMicros: 0))

            try await harness.recorder.waitFor(.displaySelected(displayID))
        }
    }

    @Test func invalidSelectDisplayIsDroppedAndConnectionStaysUp() async throws {
        try await withPairedClient { harness, _, client in
            client.send(Frame(type: .selectDisplay, timestampMicros: 0, payload: Data(#"{"displayID":"nope"}"#.utf8)))
            client.send(try SessionMessageCoding.frame(for: SelectDisplay(displayID: displayID), timestampMicros: 1))

            try await harness.recorder.waitFor(.displaySelected(displayID))
            #expect(harness.recorder.count { if case .displaySelected = $0 { true } else { false } } == 1)
            #expect(!client.isClosed)
        }
    }

    @Test func newPairedConnectionReplacesTheActiveSession() async throws {
        try await withPairedClient { harness, phone, first in
            let second = try harness.connect(phone)
            defer { second.close() }

            try await harness.recorder.waitFor(.clientConnected(phone.fingerprint), count: 2)
            try await first.waitUntilClosed()
            #expect(harness.recorder.contains(.clientDisconnected(phone.fingerprint)))
            #expect(!second.isClosed)
        }
    }

    @Test func unpairedClientIsRefusedWhenNoPairingWindowIsOpen() async throws {
        try await ServerHarness.run(phones: ["Stranger"]) { harness, phones in
            let stranger = try harness.connect(phones[0])
            defer { stranger.close() }

            try await stranger.waitUntilClosed()
            #expect(harness.recorder.count { if case .clientConnected = $0 { true } else { false } } == 0)
        }
    }
}
