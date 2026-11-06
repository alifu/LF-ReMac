import AVFoundation
import Foundation
import RemoteCore

/// Plays the Mac's audio: AAC -> PCM -> `AVAudioPlayerNode`, kept shallow by `AudioPlaybackModel` so sound
/// stays close to the picture (video is shown the moment it arrives).
///
/// Everything runs on one private queue; call `setActive` and `handle` from anywhere.
final class AudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.alifu.lfremac.audioplayer", qos: .userInteractive)
    private let logger = AppLog.logger(category: "audio")
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var decoder: AACDecoder?
    private var model = AudioPlaybackModel()
    private var isActive = false
    private var isGraphBuilt = false
    private var observers: [NSObjectProtocol] = []

    /// Turns playback on or off. Off releases the audio session so other apps get the speaker back.
    func setActive(_ active: Bool) {
        queue.async { active ? self.activate() : self.deactivate() }
    }

    /// Feed `audioConfig` and `audioFrame` frames; others and anything while off are ignored.
    func handle(_ frame: Frame) {
        queue.async {
            guard self.isActive else { return }
            switch frame.type {
            case .audioConfig: self.configure(frame)
            case .audioFrame: self.play(frame)
            default: break
            }
        }
    }

    // MARK: - Lifecycle (on queue)

    private func activate() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            logger.error("Audio session failed: \(String(describing: error), privacy: .public)")
            return
        }
        isActive = true
        model.reset()
        observe()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        node.stop()
        engine.stop()
        decoder = nil
        model.reset()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.notice("Releasing the audio session failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                self?.queue.async { self?.interruption(type) }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.queue.async { self?.resume() }
            },
        ]
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        guard isActive else { return }
        switch type {
        case .began:
            node.stop()
            model.reset()
        case .ended:
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                logger.error("Audio session did not come back: \(String(describing: error), privacy: .public)")
                return
            }
            resume()
        default:
            break
        }
    }

    /// After an interruption or a route change: restart the engine and wait for fresh audio.
    private func resume() {
        guard isActive else { return }
        node.stop()
        model.reset()
        startEngine()
    }

    // MARK: - Audio (on queue)

    private func configure(_ frame: Frame) {
        do {
            let config = try SessionMessageCoding.audioConfig(from: frame)
            let decoder = try AACDecoder(config: config)
            node.stop()
            if isGraphBuilt {
                engine.disconnectNodeOutput(node)
            } else {
                engine.attach(node)
                isGraphBuilt = true
            }
            engine.connect(node, to: engine.mainMixerNode, format: decoder.pcmFormat)
            self.decoder = decoder
            model.reset()
            startEngine()
        } catch {
            logger.error("Ignored audio config: \(String(describing: error), privacy: .public)")
        }
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            logger.error("Audio engine did not start: \(String(describing: error), privacy: .public)")
        }
    }

    private func play(_ frame: Frame) {
        guard let decoder, engine.isRunning else { return }
        do {
            let pcm = try decoder.decode(try SessionMessageCoding.audioAccessUnit(from: frame))
            let milliseconds = Double(pcm.frameLength) * 1000 / pcm.format.sampleRate
            let (action, generation) = model.ingest(frameMilliseconds: milliseconds)
            if action == .catchUp { node.stop() }
            node.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { self?.finished(milliseconds: milliseconds, generation: generation) }
            }
            if action == .start || action == .catchUp { node.play() }
        } catch {
            logger.error("Dropped an audio frame: \(String(describing: error), privacy: .public)")
        }
    }

    private func finished(milliseconds: Double, generation: Int) {
        guard isActive, model.played(milliseconds: milliseconds, generation: generation) else { return }
        node.stop()
    }
}
