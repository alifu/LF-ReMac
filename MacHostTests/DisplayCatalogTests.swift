import CoreGraphics
import Foundation
import RemoteCore
import Testing
@testable import MacHost

struct DisplayCatalogTests {
    private let main = DisplayDescriptor(
        uuid: "11111111-2222-3333-4444-555555555555", name: "Built-in", pixelWidth: 3024, pixelHeight: 1964,
        isMain: true, displayID: 1
    )
    private let external = DisplayDescriptor(
        uuid: "66666666-7777-8888-9999-AAAAAAAAAAAA", name: "LG", pixelWidth: 2560, pixelHeight: 1440,
        isMain: false, displayID: 5
    )

    @Test func resolvesTheRequestedDisplay() {
        #expect(DisplayCatalog.resolve(external.uuid, in: [main, external]) == external)
    }

    @Test func fallsBackToMainWhenTheRequestedDisplayIsGone() {
        #expect(DisplayCatalog.resolve(external.uuid, in: [main]) == main)
        #expect(DisplayCatalog.resolve(nil, in: [external, main]) == main)
    }

    @Test func fallsBackToTheFirstDisplayWhenNoneIsMain() {
        #expect(DisplayCatalog.resolve(nil, in: [external]) == external)
    }

    @Test func resolvesNilWithoutDisplays() {
        #expect(DisplayCatalog.resolve("anything", in: []) == nil)
    }

    @Test func hostInfoMarksTheResolvedDisplayAsSelected() {
        let info = DisplayCatalog.hostInfo(displays: [main, external], selectedUUID: external.uuid)

        #expect(info.selectedID == external.uuid)
        #expect(info.displays.map(\.id) == [main.uuid, external.uuid])
        #expect(info.displays.first?.isMain == true)
    }

    @Test func hostInfoSelectsMainWhenSelectionIsUnknown() {
        #expect(DisplayCatalog.hostInfo(displays: [main], selectedUUID: "gone").selectedID == main.uuid)
    }

    @Test func hostInfoWithNoDisplaysHasNoSelection() {
        #expect(DisplayCatalog.hostInfo(displays: [], selectedUUID: nil).selectedID == nil)
    }

    @Test func hostInfoPassesTheWireValidation() throws {
        let long = DisplayDescriptor(
            uuid: external.uuid, name: String(repeating: "x", count: 200), pixelWidth: 100, pixelHeight: 100,
            isMain: false, displayID: 9
        )
        let info = DisplayCatalog.hostInfo(displays: [main, long], selectedUUID: nil)

        let frame = try SessionMessageCoding.frame(for: info, timestampMicros: 0)

        #expect(try SessionMessageCoding.hostInfo(from: frame) == info)
    }

    @Test func hostInfoKeepsAtMostTheWireLimitOfDisplays() throws {
        let many = (0..<20).map {
            DisplayDescriptor(
                uuid: String(format: "00000000-0000-0000-0000-%012d", $0), name: "D\($0)", pixelWidth: 10, pixelHeight: 10,
                isMain: $0 == 0, displayID: CGDirectDisplayID($0 + 1)
            )
        }

        let info = DisplayCatalog.hostInfo(displays: many, selectedUUID: many[19].uuid)

        #expect(info.displays.count == SessionMessageCoding.maxDisplays)
        _ = try SessionMessageCoding.hostInfo(from: SessionMessageCoding.frame(for: info, timestampMicros: 0))
    }

    @Test func needsRestartOnlyWhenTheCapturedDisplayOrItsSizeChanges() {
        let resized = DisplayDescriptor(
            uuid: main.uuid, name: main.name, pixelWidth: 1512, pixelHeight: 982, isMain: true, displayID: 1
        )

        #expect(!DisplayCatalog.needsRestart(from: main, to: main))
        #expect(DisplayCatalog.needsRestart(from: main, to: external))
        #expect(DisplayCatalog.needsRestart(from: main, to: resized))
        #expect(DisplayCatalog.needsRestart(from: nil, to: main))
        #expect(!DisplayCatalog.needsRestart(from: nil, to: nil))
    }
}
