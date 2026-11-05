import Foundation
import RemoteCore
import Testing
@testable import MacHost

struct EncodedVideoEventFrameTests {
    @Test func configEventBecomesVideoConfigFrame() {
        let event = EncodedVideoEvent.config(Data([0, 0, 0, 1, 0x67]))

        let frame = event.asFrame

        #expect(frame == Frame(type: .videoConfig, timestampMicros: 0, payload: Data([0, 0, 0, 1, 0x67])))
    }

    @Test func keyframeEventSetsKeyframeFlag() {
        let event = EncodedVideoEvent.frame(data: Data([9]), isKeyframe: true, presentationTimeMicros: 42)

        let frame = event.asFrame

        #expect(frame == Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 42, payload: Data([9])))
    }

    @Test func deltaFrameEventHasNoFlags() {
        let event = EncodedVideoEvent.frame(data: Data([9]), isKeyframe: false, presentationTimeMicros: 7)

        #expect(event.asFrame.flags.isEmpty)
    }
}
