import AppKit
import SwiftUI

#if DEBUG
/// Drives the debug clip recording shown in the menu (Debug builds only: it writes raw screen content to disk).
@MainActor
@Observable
final class TestClipModel {
    enum State: Equatable {
        case idle
        case recording
        case saved(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private let recorder = PipelineRecorder()

    var isRecording: Bool { state == .recording }

    func recordClip() async {
        guard !isRecording else { return }
        state = .recording
        do {
            state = .saved(try await recorder.record())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

#endif

struct HostMenuView: View {
    let session: HostSession
    #if DEBUG
    @State private var clipModel = TestClipModel()
    #endif

    var body: some View {
        HostingSection(session: session)
        Divider()
        PairingMenuSection(session: session)
        Divider()
        #if DEBUG
        TestClipSection(model: clipModel)
        Divider()
        #endif
        Button("Quit LF-ReMac") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

#if DEBUG
private struct TestClipSection: View {
    let model: TestClipModel

    var body: some View {
        Button(model.isRecording ? "Recording…" : "Record 10s Test Clip") {
            Task { await model.recordClip() }
        }
        .disabled(model.isRecording)
        status
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .idle, .recording:
            EmptyView()
        case .saved(let url):
            Text("Saved \(url.lastPathComponent)")
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failed(let message):
            Text(message)
        }
    }
}
#endif
