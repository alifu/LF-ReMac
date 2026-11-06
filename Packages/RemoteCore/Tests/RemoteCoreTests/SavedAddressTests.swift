import Testing
@testable import RemoteCore

struct SavedAddressValidationTests {
    private func validationError(hostText: String, portText: String = "47800") -> SavedAddressError? {
        if case .failure(let error) = SavedAddress.validate(hostText: hostText, portText: portText) { return error }
        return nil
    }

    @Test func acceptsAnIPAddressAndPort() throws {
        let address = try SavedAddress.validate(hostText: "100.101.102.103", portText: "47800").get()

        #expect(address.host == "100.101.102.103")
        #expect(address.port == 47800)
    }

    @Test func acceptsAMagicDNSName() throws {
        let address = try SavedAddress.validate(hostText: "mac-mini.tail1234.ts.net", portText: "47800").get()

        #expect(address.host == "mac-mini.tail1234.ts.net")
    }

    @Test func trimsSurroundingWhitespaceFromHostAndPort() throws {
        let address = try SavedAddress.validate(hostText: "  mac-mini.local \n", portText: " 47801 ").get()

        #expect(address.host == "mac-mini.local")
        #expect(address.port == 47801)
    }

    @Test func rejectsAnEmptyHost() {
        #expect(validationError(hostText: "   ", portText: "47800") == .emptyHost)
    }

    @Test func rejectsAHostContainingSpaces() {
        #expect(validationError(hostText: "mac mini.local", portText: "47800") == .hostContainsSpaces)
    }

    @Test func acceptsAHostOf253CharactersAndRejectsOneLonger() throws {
        let longest = String(repeating: "a", count: 253)

        #expect(try SavedAddress.validate(hostText: longest, portText: "47800").get().host == longest)
        #expect(validationError(hostText: longest + "a", portText: "47800") == .hostTooLong)
    }

    @Test func acceptsPortBoundsOneAndSixtyFiveThousandFiveHundredThirtyFive() throws {
        #expect(try SavedAddress.validate(hostText: "mac.local", portText: "1").get().port == 1)
        #expect(try SavedAddress.validate(hostText: "mac.local", portText: "65535").get().port == 65535)
    }

    @Test func rejectsPortsOutsideTheValidRangeOrNotANumber() {
        for portText in ["", "0", "65536", "-1", "abc", "47800.5"] {
            #expect(validationError(hostText: "mac.local", portText: portText) == .invalidPort, "port \(portText)")
        }
    }

    @Test func everyErrorHasAUserMessage() {
        let errors: [SavedAddressError] = [.emptyHost, .hostContainsSpaces, .hostTooLong, .invalidPort]

        for error in errors {
            #expect(!error.message.isEmpty)
        }
    }
}
