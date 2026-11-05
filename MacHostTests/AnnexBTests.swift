import CoreMedia
import Foundation
import Testing
@testable import MacHost

struct AnnexBTests {
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    @Test func convertsSingleFourByteLengthNAL() throws {
        let avcc: [UInt8] = [0x00, 0x00, 0x00, 0x03, 0x65, 0xAA, 0xBB]

        let annexB = try AnnexB.fromAVCC(Data(avcc), nalLengthSize: 4)

        #expect(Array(annexB) == startCode + [0x65, 0xAA, 0xBB])
    }

    @Test func convertsMultipleNALsInOrder() throws {
        let avcc: [UInt8] = [
            0x00, 0x00, 0x00, 0x02, 0x06, 0x01,        // SEI
            0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x99, // IDR slice
        ]

        let annexB = try AnnexB.fromAVCC(Data(avcc), nalLengthSize: 4)

        #expect(Array(annexB) == startCode + [0x06, 0x01] + startCode + [0x65, 0x88, 0x99])
    }

    @Test func supportsShortLengthPrefixes() throws {
        let twoByte: [UInt8] = [0x00, 0x02, 0x41, 0x9A]
        let oneByte: [UInt8] = [0x01, 0x41]

        #expect(Array(try AnnexB.fromAVCC(Data(twoByte), nalLengthSize: 2)) == startCode + [0x41, 0x9A])
        #expect(Array(try AnnexB.fromAVCC(Data(oneByte), nalLengthSize: 1)) == startCode + [0x41])
    }

    @Test func handlesDataSlicesWithNonZeroStartIndex() throws {
        let backing = Data([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x41])
        let slice = backing.dropFirst(2)

        let annexB = try AnnexB.fromAVCC(slice, nalLengthSize: 4)

        #expect(Array(annexB) == startCode + [0x41])
    }

    @Test func emptyInputProducesEmptyOutput() throws {
        #expect(try AnnexB.fromAVCC(Data(), nalLengthSize: 4).isEmpty)
    }

    @Test func rejectsTruncatedNAL() {
        let avcc: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x65, 0x01]

        #expect(throws: H264EncoderError.malformedSampleData) {
            try AnnexB.fromAVCC(Data(avcc), nalLengthSize: 4)
        }
    }

    @Test func rejectsTruncatedLengthPrefix() {
        #expect(throws: H264EncoderError.malformedSampleData) {
            try AnnexB.fromAVCC(Data([0x00, 0x00]), nalLengthSize: 4)
        }
    }

    @Test func rejectsZeroLengthNAL() {
        #expect(throws: H264EncoderError.malformedSampleData) {
            try AnnexB.fromAVCC(Data([0x00, 0x00, 0x00, 0x00]), nalLengthSize: 4)
        }
    }

    @Test func rejectsUnsupportedLengthSize() {
        #expect(throws: H264EncoderError.malformedSampleData) {
            try AnnexB.fromAVCC(Data([0x00, 0x00, 0x01, 0x41]), nalLengthSize: 3)
        }
    }

    @Test func joinsParameterSetsWithStartCodes() {
        let sps = Data([0x67, 0x42])
        let pps = Data([0x68, 0xCE])

        let joined = AnnexB.joined([sps, pps])

        #expect(Array(joined) == startCode + [0x67, 0x42] + startCode + [0x68, 0xCE])
    }

    @Test func splitsAnnexBBackIntoNALUnits() {
        let stream = Data(startCode + [0x67, 0x42] + startCode + [0x68, 0xCE])

        let units = AnnexB.nalUnits(in: stream)

        #expect(units == [Data([0x67, 0x42]), Data([0x68, 0xCE])])
    }

    @Test func convertsPresentationTimeToMicroseconds() {
        #expect(EncodedVideoEvent.micros(from: CMTime(value: 3, timescale: 2)) == 1_500_000)
        #expect(EncodedVideoEvent.micros(from: .invalid) == 0)
        #expect(EncodedVideoEvent.micros(from: CMTime(value: -5, timescale: 1)) == 0)
    }
}
