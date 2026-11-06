import Foundation
import Testing
@testable import RemoteCore

struct AudioMessageTests {
    private let config = AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 2, frameSamples: 1024, audioSpecificConfig: Data([0x11, 0x90]))

    @Test func newTypesKeepTheirWireValues() {
        #expect(MessageType.audioConfig.rawValue == 11)
        #expect(MessageType.audioFrame.rawValue == 12)
        #expect(MessageType.audioControl.rawValue == 13)
    }

    @Test func audioConfigRoundTrips() throws {
        let frame = try SessionMessageCoding.frame(for: config, timestampMicros: 1)

        #expect(frame.type == .audioConfig)
        #expect(try SessionMessageCoding.audioConfig(from: frame) == config)
    }

    @Test func audioControlRoundTrips() throws {
        for enabled in [true, false] {
            let frame = try SessionMessageCoding.frame(for: AudioControl(enabled: enabled), timestampMicros: 1)
            #expect(frame.type == .audioControl)
            #expect(try SessionMessageCoding.audioControl(from: frame).enabled == enabled)
        }
    }

    @Test func frameDurationFollowsSampleRate() {
        #expect(abs(config.frameDurationMilliseconds - 21.333) < 0.01)
    }

    @Test func rejectsInvalidAudioConfigs() throws {
        let bad: [AudioConfig] = [
            AudioConfig(codec: .aacLC, sampleRate: 8_000, channels: 2, frameSamples: 1024, audioSpecificConfig: Data([1, 2])),
            AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 0, frameSamples: 1024, audioSpecificConfig: Data([1, 2])),
            AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 6, frameSamples: 1024, audioSpecificConfig: Data([1, 2])),
            AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 2, frameSamples: 77, audioSpecificConfig: Data([1, 2])),
            AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 2, frameSamples: 1024, audioSpecificConfig: Data()),
            AudioConfig(codec: .aacLC, sampleRate: 48_000, channels: 2, frameSamples: 1024, audioSpecificConfig: Data(repeating: 1, count: 65)),
        ]
        for config in bad {
            let frame = try SessionMessageCoding.frame(for: config, timestampMicros: 0)
            #expect(throws: SessionMessageError.invalidField) { try SessionMessageCoding.audioConfig(from: frame) }
        }
    }

    @Test func unknownCodecIsAMalformedPayload() {
        let json = #"{"codec":"mp3","sampleRate":48000,"channels":2,"frameSamples":1024,"audioSpecificConfig":"EZA="}"#
        let frame = Frame(type: .audioConfig, timestampMicros: 0, payload: Data(json.utf8))
        #expect(throws: SessionMessageError.malformedPayload) { try SessionMessageCoding.audioConfig(from: frame) }
    }

    @Test func audioFramePayloadIsTheRawAccessUnit() throws {
        let aac = Data([9, 8, 7, 6])

        let frame = try SessionMessageCoding.audioFrame(aac: aac, timestampMicros: 77)

        #expect(frame.type == .audioFrame)
        #expect(frame.timestampMicros == 77)
        #expect(try SessionMessageCoding.audioAccessUnit(from: frame) == aac)
    }

    @Test func rejectsEmptyOrOversizedAudioFrames() throws {
        #expect(throws: SessionMessageError.invalidField) { try SessionMessageCoding.audioFrame(aac: Data(), timestampMicros: 0) }
        let big = Data(repeating: 1, count: SessionMessageCoding.maxAudioFrameBytes + 1)
        #expect(throws: SessionMessageError.payloadTooLarge(big.count)) { try SessionMessageCoding.audioFrame(aac: big, timestampMicros: 0) }
        let wire = Frame(type: .audioFrame, timestampMicros: 0, payload: big)
        #expect(throws: SessionMessageError.payloadTooLarge(big.count)) { try SessionMessageCoding.audioAccessUnit(from: wire) }
    }

    @Test func audioNeedsTheAudioCapability() {
        let withAudio = PeerCapabilities(hello: ClientHello(protocolVersion: 1, capabilities: [.audio]))
        let withoutAudio = PeerCapabilities(hello: ClientHello(protocolVersion: 1, capabilities: [.displays]))

        #expect(withAudio.canReceive(.audioConfig))
        #expect(withAudio.canReceive(.audioFrame))
        #expect(!withoutAudio.canReceive(.audioConfig))
        #expect(!withoutAudio.canReceive(.audioFrame))
        #expect(!PeerCapabilities.legacy.canReceive(.audioFrame))
        #expect(!withAudio.canReceive(.audioControl))
    }

    @Test func allowListsCarryAudioInTheRightDirection() {
        #expect(ProtocolTypes.hostAcceptsFromPairedClient.contains(.audioControl))
        #expect(!ProtocolTypes.hostAcceptsFromPairedClient.contains(.audioFrame))
        #expect(ProtocolTypes.clientAcceptsFromHost.contains(.audioConfig))
        #expect(ProtocolTypes.clientAcceptsFromHost.contains(.audioFrame))
        #expect(!ProtocolTypes.clientAcceptsFromHost.contains(.audioControl))
    }
}

struct AudioJitterPolicyTests {
    private let frameMs = 21.333
    private var policy = AudioJitterPolicy()

    @Test func holdsUntilEnoughAudioIsBufferedThenStarts() {
        var policy = AudioJitterPolicy()

        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 0) == .hold)
        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: frameMs) == .start)
        #expect(policy.isPlaying)
    }

    @Test func playsNormallyOnceStarted() {
        var policy = AudioJitterPolicy()
        _ = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 30)

        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 40) == .play)
        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 60) == .play)
    }

    @Test func dropsStaleAudioInsteadOfLettingDelayGrow() {
        var policy = AudioJitterPolicy()
        _ = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 30)

        let action = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 110)

        #expect(action == .catchUp)
        #expect(policy.isPlaying)
        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: frameMs) == .play)
    }

    @Test func exactlyAtTheLimitIsStillFine() {
        var policy = AudioJitterPolicy()
        _ = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 30)

        #expect(policy.ingest(frameMilliseconds: 20, bufferedMilliseconds: 100) == .play)
    }

    @Test func anUnderrunMeansRebufferingBeforePlayingAgain() {
        var policy = AudioJitterPolicy()
        _ = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 30)

        policy.underrun()

        #expect(!policy.isPlaying)
        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 0) == .hold)
        #expect(policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: frameMs) == .start)
    }

    @Test func resetStartsOver() {
        var policy = AudioJitterPolicy()
        _ = policy.ingest(frameMilliseconds: frameMs, bufferedMilliseconds: 30)

        policy.reset()

        #expect(!policy.isPlaying)
    }

    @Test func settingsAreKeptInOrder() {
        let odd = AudioJitterPolicy(startMilliseconds: 200, maxMilliseconds: 50)

        #expect(odd.startMilliseconds < odd.maxMilliseconds)
    }
}
