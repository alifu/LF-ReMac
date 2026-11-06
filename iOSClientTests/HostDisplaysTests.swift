import Foundation
import RemoteCore
import Testing
@testable import iOSClient

struct HostDisplaysTests {
    private let builtIn = DisplayInfo(
        id: "11111111-2222-3333-4444-555555555555", name: "Built-in", pixelWidth: 3024, pixelHeight: 1964, isMain: true)
    private let external = DisplayInfo(
        id: "66666666-7777-8888-9999-AAAAAAAAAAAA", name: "LG", pixelWidth: 2560, pixelHeight: 1440, isMain: false)

    private func info(_ displays: [DisplayInfo], selected: DisplayInfo?) -> HostInfo {
        HostInfo(displays: displays, selectedID: selected?.id, wakeMACs: [], virtualDisplaySupported: false)
    }

    @Test func startsWithNothingToChoose() {
        #expect(!HostDisplays.none.canChoose)
        #expect(HostDisplays.none.selected == nil)
    }

    @Test func oneDisplayOffersNoChoice() {
        let displays = HostDisplays(info([builtIn], selected: builtIn))

        #expect(!displays.canChoose)
        #expect(displays.selected == builtIn)
    }

    @Test func twoDisplaysOfferAChoiceAndKnowTheSelectedOne() {
        let displays = HostDisplays(info([builtIn, external], selected: external))

        #expect(displays.canChoose)
        #expect(displays.selected == external)
        #expect(displays.isSelected(external))
        #expect(!displays.isSelected(builtIn))
    }

    @Test func noSelectionLeavesNothingSelected() {
        let displays = HostDisplays(info([builtIn, external], selected: nil))

        #expect(displays.selected == nil)
        #expect(!displays.isSelected(builtIn))
    }

    @Test func labelShowsNameAndPixelSize() {
        #expect(HostDisplays.label(for: external) == "LG (2560×1440)")
    }

    @Test func blankNamesFallBackToADescriptiveLabel() {
        let unnamed = DisplayInfo(id: external.id, name: " ", pixelWidth: 100, pixelHeight: 50, isMain: false)

        #expect(HostDisplays.label(for: unnamed) == "Display (100×50)")
    }
}
