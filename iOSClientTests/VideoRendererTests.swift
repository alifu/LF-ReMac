import Foundation
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct VideoRendererTests {
    private func deltaFrame() -> Frame {
        Frame(type: .videoFrame, timestampMicros: 1, payload: Data([0, 0, 0, 1, 0x41, 0x9A]))
    }

    @Test func requestsKeyframeWhenVideoArrivesBeforeConfig() {
        let renderer = VideoRenderer()
        let requests = Counter()
        renderer.onKeyframeNeeded = { requests.increment() }

        renderer.handle(deltaFrame())

        #expect(requests.value == 1)
    }

    @Test func requestsKeyframeOnlyOnceWhileWaiting() {
        let renderer = VideoRenderer()
        let requests = Counter()
        renderer.onKeyframeNeeded = { requests.increment() }

        renderer.handle(deltaFrame())
        renderer.handle(deltaFrame())
        renderer.handle(deltaFrame())

        #expect(requests.value == 1)
    }

    @Test func ignoresInvalidConfigWithoutCrashing() {
        let renderer = VideoRenderer()

        renderer.handle(Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1, 2, 3])))

        #expect(renderer.isAwaitingKeyframe)
    }

    @Test func ignoresNonVideoFrames() {
        let renderer = VideoRenderer()
        let requests = Counter()
        renderer.onKeyframeNeeded = { requests.increment() }

        renderer.handle(Frame(type: .ping, timestampMicros: 0, payload: Data()))

        #expect(requests.value == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
