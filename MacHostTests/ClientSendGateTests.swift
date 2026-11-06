import Foundation
import RemoteCore
import Testing
@testable import MacHost

struct ClientSendGateTests {
    private func config() -> Frame {
        Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1]))
    }

    private func keyframe() -> Frame {
        Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 1, payload: Data([2]))
    }

    private func deltaFrame() -> Frame {
        Frame(type: .videoFrame, timestampMicros: 2, payload: Data([3]))
    }

    @Test func dropsDeltaFramesUntilConfigAndKeyframeArrive() {
        var gate = ClientSendGate()

        #expect(gate.decide(for: deltaFrame()) == .drop)
        #expect(gate.decide(for: keyframe()) == .drop)
    }

    @Test func sendsConfigThenKeyframeThenDeltaFrames() {
        var gate = ClientSendGate()

        #expect(gate.decide(for: config()) == .send)
        #expect(gate.decide(for: keyframe()) == .send)
        #expect(gate.decide(for: deltaFrame()) == .send)
    }

    @Test func dropsFramesWhenBacklogIsFullAndRequestsKeyframeOnce() {
        var gate = ClientSendGate(maxPendingFrames: 2)
        _ = gate.decide(for: config())
        _ = gate.decide(for: keyframe())

        let first = gate.decide(for: deltaFrame())
        let second = gate.decide(for: deltaFrame())

        #expect(first == .dropAndRequestKeyframe)
        #expect(second == .drop)
    }

    @Test func resumesOnlyAtNextConfigAndKeyframeAfterBacklogClears() {
        var gate = ClientSendGate(maxPendingFrames: 2)
        _ = gate.decide(for: config())
        _ = gate.decide(for: keyframe())
        _ = gate.decide(for: deltaFrame())
        gate.sendCompleted()
        gate.sendCompleted()

        _ = gate.decide(for: deltaFrame())
        #expect(gate.decide(for: deltaFrame()) == .drop)
        #expect(gate.decide(for: config()) == .send)
        #expect(gate.decide(for: keyframe()) == .send)
    }

    @Test func asksForAnotherKeyframeOnceTheBacklogHasDrained() {
        var gate = ClientSendGate(maxPendingFrames: 2)
        _ = gate.decide(for: config())
        _ = gate.decide(for: keyframe())
        #expect(gate.decide(for: deltaFrame()) == .dropAndRequestKeyframe)
        gate.sendCompleted()
        gate.sendCompleted()

        #expect(gate.decide(for: deltaFrame()) == .requestKeyframe)
        #expect(gate.decide(for: deltaFrame()) == .drop)
    }

    @Test func doesNotAskAgainWhileTheBacklogIsStillFull() {
        var gate = ClientSendGate(maxPendingFrames: 2)
        _ = gate.decide(for: config())
        _ = gate.decide(for: keyframe())
        _ = gate.decide(for: deltaFrame())

        #expect(gate.decide(for: deltaFrame()) == .drop)
        #expect(gate.decide(for: deltaFrame()) == .drop)
    }

    @Test func aNewClientNeverTriggersARetryRequest() {
        var gate = ClientSendGate()

        #expect(gate.decide(for: deltaFrame()) == .drop)
    }

    @Test func controlMessagesAlwaysPassTheGate() {
        var gate = ClientSendGate()
        let ping = Frame(type: .ping, timestampMicros: 5, payload: Data())

        #expect(gate.decide(for: ping) == .send)
    }

    @Test func sendCompletedNeverGoesBelowZeroPending() {
        var gate = ClientSendGate()

        gate.sendCompleted()
        gate.sendCompleted()

        #expect(gate.pendingSends == 0)
    }
}
