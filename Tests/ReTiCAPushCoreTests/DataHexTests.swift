import Testing
import Foundation
@testable import ReTiCAPushCore

@Test func hexRoundTripsLowercase() {
    #expect(Data([0xDE, 0xAD, 0x01]).hexString == "dead01")
    #expect(Data(hexString: "dead01") == Data([0xDE, 0xAD, 0x01]))
}

@Test func hexRejectsOddLength() {
    #expect(Data(hexString: "abc") == nil)
}

@Test func hexRejectsNonHexCharacters() {
    #expect(Data(hexString: "zz") == nil)
}
