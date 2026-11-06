import CoreGraphics
import Foundation
import RemoteCore

/// One Mac display as seen at a point in time. `uuid` is stable across replugging; `displayID` is not.
struct DisplayDescriptor: Equatable, Sendable {
    let uuid: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool
    let displayID: CGDirectDisplayID
}

/// Pure rules for choosing which display to stream and describing the choice to the iPhone.
enum DisplayCatalog {
    /// The requested display; otherwise the main one, then the first. Nil only when there are no displays.
    static func resolve(_ requestedUUID: String?, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        if let requestedUUID, let match = displays.first(where: { $0.uuid == requestedUUID }) { return match }
        return displays.first(where: \.isMain) ?? displays.first
    }

    /// What to tell the iPhone. The selection is the display actually being captured (after fallback).
    /// Trimmed to the wire limits so the message always validates.
    static func hostInfo(
        displays: [DisplayDescriptor], selectedUUID: String?,
        wakeMACs: [String] = [], virtualDisplaySupported: Bool = false
    ) -> HostInfo {
        let selected = resolve(selectedUUID, in: displays)
        var listed = Array(displays.prefix(SessionMessageCoding.maxDisplays))
        // Keep the selected display in the list even if it sorted past the limit.
        if let selected, !listed.contains(selected) { listed[listed.count - 1] = selected }
        return HostInfo(
            displays: listed.map {
                DisplayInfo(
                    id: $0.uuid, name: String($0.name.prefix(SessionMessageCoding.maxNameLength)),
                    pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, isMain: $0.isMain
                )
            },
            selectedID: selected?.uuid,
            wakeMACs: wakeMACs,
            virtualDisplaySupported: virtualDisplaySupported
        )
    }

    /// Capture must be rebuilt when the display or its pixel size changes (the encoder size is fixed).
    static func needsRestart(from old: DisplayDescriptor?, to new: DisplayDescriptor?) -> Bool {
        guard let old, let new else { return old != nil || new != nil }
        return old.displayID != new.displayID || old.pixelWidth != new.pixelWidth || old.pixelHeight != new.pixelHeight
    }
}
