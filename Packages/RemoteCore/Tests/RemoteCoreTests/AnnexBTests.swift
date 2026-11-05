import Foundation
import Testing
@testable import RemoteCore

struct AnnexBTests {
    private let fourByte: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private let threeByte: [UInt8] = [0x00, 0x00, 0x01]

    // MARK: - nalUnits

    @Test func splitsOnFourByteStartCodes() {
        let stream = Data(fourByte + [0x67, 0x42] + fourByte + [0x68, 0xCE])

        let units = AnnexB.nalUnits(in: stream)

        #expect(units == [Data([0x67, 0x42]), Data([0x68, 0xCE])])
    }

    @Test func splitsOnThreeByteStartCodes() {
        let stream = Data(threeByte + [0x41, 0x9A] + threeByte + [0x41, 0x9B, 0x03])

        let units = AnnexB.nalUnits(in: stream)

        #expect(units == [Data([0x41, 0x9A]), Data([0x41, 0x9B, 0x03])])
    }

    @Test func splitsMixedStartCodesWithoutLeakingZeroIntoPreviousUnit() {
        let stream = Data(threeByte + [0x06, 0x05] + fourByte + [0x65, 0x88])

        let units = AnnexB.nalUnits(in: stream)

        #expect(units == [Data([0x06, 0x05]), Data([0x65, 0x88])])
    }

    @Test func dropsTrailingZeroBytesAndEmptyUnits() {
        let stream = Data(fourByte + [0x65, 0x01, 0x00, 0x00] + fourByte + fourByte + [0x41])

        let units = AnnexB.nalUnits(in: stream)

        #expect(units == [Data([0x65, 0x01]), Data([0x41])])
    }

    @Test func ignoresBytesBeforeFirstStartCode() {
        let stream = Data([0xFF, 0xAB] + fourByte + [0x41, 0x02])

        #expect(AnnexB.nalUnits(in: stream) == [Data([0x41, 0x02])])
    }

    @Test func preservesEmulationPreventionBytes() {
        let payload: [UInt8] = [0x65, 0x00, 0x00, 0x03, 0x01]

        #expect(AnnexB.nalUnits(in: Data(fourByte + payload)) == [Data(payload)])
    }

    @Test(arguments: [
        Data(),
        Data([0x00]),
        Data([0x00, 0x00]),
        Data([0x12, 0x34, 0x56, 0x78, 0x9A]),
        Data([0x00, 0x00, 0x00, 0x01]),
        Data([0x00, 0x00, 0x00, 0x00, 0x00]),
    ])
    func returnsNoUnitsForEmptyOrGarbageInput(stream: Data) {
        #expect(AnnexB.nalUnits(in: stream).isEmpty)
    }

    @Test func handlesDataSliceWithNonZeroStartIndex() {
        let backing = Data([0xFF] + fourByte + [0x41])

        #expect(AnnexB.nalUnits(in: backing.dropFirst()) == [Data([0x41])])
    }

    @Test func splitIsInverseOfJoined() {
        let units = [Data([0x67, 0x42, 0x00, 0x1F]), Data([0x68, 0xCE])]

        #expect(AnnexB.nalUnits(in: AnnexB.joined(units)) == units)
    }

    // MARK: - AVCC

    @Test func convertsAnnexBToFourByteBigEndianLengths() throws {
        let long = [UInt8](repeating: 0x7F, count: 300)
        let stream = Data(fourByte + [0x06, 0x01] + threeByte + [0x65] + long)

        let avcc = try AnnexB.toAVCC(stream)

        #expect(Array(avcc) == [0, 0, 0, 2, 0x06, 0x01] + [0, 0, 0x01, 0x2D, 0x65] + long)
    }

    @Test func annexBToAVCCRoundTripsThroughFromAVCC() throws {
        let stream = Data(fourByte + [0x41, 0x9A, 0x10] + fourByte + [0x41, 0x01])

        let roundTripped = try AnnexB.fromAVCC(try AnnexB.toAVCC(stream), nalLengthSize: 4)

        #expect(roundTripped == stream)
    }

    @Test(arguments: [Data(), Data([0x65, 0x88, 0x84]), Data([0x00, 0x00, 0x00, 0x01])])
    func toAVCCRejectsStreamWithoutNALUnits(stream: Data) {
        #expect(throws: AnnexBError.noNALUnits) { try AnnexB.toAVCC(stream) }
    }

    @Test func fromAVCCConvertsShortLengthPrefixes() throws {
        #expect(Array(try AnnexB.fromAVCC(Data([0x00, 0x02, 0x41, 0x9A]), nalLengthSize: 2)) == fourByte + [0x41, 0x9A])
        #expect(Array(try AnnexB.fromAVCC(Data([0x01, 0x41]), nalLengthSize: 1)) == fourByte + [0x41])
    }

    @Test func fromAVCCRejectsMalformedInput() {
        #expect(throws: AnnexBError.malformedAVCC) { try AnnexB.fromAVCC(Data([0, 0, 0, 5, 0x65]), nalLengthSize: 4) }
        #expect(throws: AnnexBError.malformedAVCC) { try AnnexB.fromAVCC(Data([0, 0]), nalLengthSize: 4) }
        #expect(throws: AnnexBError.malformedAVCC) { try AnnexB.fromAVCC(Data([0, 0, 0, 0]), nalLengthSize: 4) }
        #expect(throws: AnnexBError.unsupportedLengthSize(3)) { try AnnexB.fromAVCC(Data([0, 0, 1, 0x41]), nalLengthSize: 3) }
    }

    @Test func readsNALTypeFromLowFiveBits() {
        #expect(H264NALType.of(Data([0x67])) == H264NALType.sps)
        #expect(H264NALType.of(Data([0x68])) == H264NALType.pps)
        #expect(H264NALType.of(Data([0x65])) == H264NALType.idr)
        #expect(H264NALType.of(Data()) == nil)
    }
}
