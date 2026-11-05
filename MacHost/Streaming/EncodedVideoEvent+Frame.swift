import Foundation
import RemoteCore

extension EncodedVideoEvent {
    /// The wire message for this encoder output.
    var asFrame: Frame {
        switch self {
        case .config(let parameterSets):
            Frame(type: .videoConfig, timestampMicros: 0, payload: parameterSets)
        case .frame(let data, let isKeyframe, let presentationTimeMicros):
            Frame(
                type: .videoFrame,
                flags: isKeyframe ? [.keyframe] : [],
                timestampMicros: presentationTimeMicros,
                payload: data
            )
        }
    }
}
