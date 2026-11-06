import Foundation
import RemoteCore

/// The Mac's displays as last reported, for the picker. The Mac decides what is selected: after a
/// switch it sends fresh host info, so the checkmark never runs ahead of what is on screen.
struct HostDisplays: Equatable, Sendable {
    static let none = HostDisplays(displays: [], selectedID: nil)

    let displays: [DisplayInfo]
    let selectedID: String?

    init(displays: [DisplayInfo], selectedID: String?) {
        self.displays = displays
        self.selectedID = selectedID
    }

    init(_ info: HostInfo) {
        self.init(displays: info.displays, selectedID: info.selectedID)
    }

    /// Worth showing a picker only when there is something to switch to.
    var canChoose: Bool { displays.count > 1 }

    var selected: DisplayInfo? { displays.first { $0.id == selectedID } }

    func isSelected(_ display: DisplayInfo) -> Bool { display.id == selectedID }

    static func label(for display: DisplayInfo) -> String {
        let trimmed = display.name.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "Display" : trimmed
        return "\(name) (\(display.pixelWidth)×\(display.pixelHeight))"
    }
}
