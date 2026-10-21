import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

private func userInfo(_ packets: [Any], version: Int = 1) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]], "rns": ["v": version, "packets": packets]]
}

private let a = Data([0x00, 0x00, 0x01, 0x02, 0x03])
private let b = Data([0x00, 0x01, 0x09, 0x08])

@Test func pushPayloadDecodesOnePacket() throws {
    #expect(try PushPayload.decode(userInfo([a.base64EncodedString()])) == [a])
}

@Test func pushPayloadDecodesManyPacketsInOrder() throws {
    #expect(try PushPayload.decode(userInfo([b.base64EncodedString(), a.base64EncodedString()])) == [b, a])
}

@Test func pushPayloadRejectsMissingBlock() {
    #expect(throws: PushPayload.DecodeError.missingBlock) {
        try PushPayload.decode(["aps": ["alert": ["title": "New message"]]])
    }
}

@Test func pushPayloadRejectsUnsupportedVersion() {
    #expect(throws: PushPayload.DecodeError.unsupportedVersion) {
        try PushPayload.decode(userInfo([a.base64EncodedString()], version: 2))
    }
}

@Test func pushPayloadRejectsNonArray() {
    #expect(throws: PushPayload.DecodeError.notAnArray) {
        try PushPayload.decode(["rns": ["v": 1, "packets": a.base64EncodedString()]])
    }
}

@Test func pushPayloadRejectsNonBase64Entry() {
    // A good first entry, then a bad one, so the reported index is 1, not 0.
    #expect(throws: PushPayload.DecodeError.invalidEntry(1)) {
        try PushPayload.decode(userInfo([a.base64EncodedString(), "not base64!"]))
    }
}

@Test func pushPayloadRejectsAnEmptyEntry() {
    #expect(throws: PushPayload.DecodeError.invalidEntry(0)) {
        try PushPayload.decode(userInfo([Data().base64EncodedString()]))
    }
}

@Test func pushPayloadRejectsOversizeEntry() {
    let big = Data(repeating: 0x00, count: Packet.mtu + 1)
    #expect(throws: PushPayload.DecodeError.oversizeEntry(0)) {
        try PushPayload.decode(userInfo([big.base64EncodedString()]))
    }
}

@Test func pushPayloadIsPropagatedTrueForTheMarker() {
    let marker: [AnyHashable: Any] = ["aps": ["alert": ["title": "New message"]],
                                      "rns": ["v": 1, "kind": "propagated", "packets": [Any]()]]
    #expect(PushPayload.isPropagated(marker))
}

@Test func pushPayloadIsPropagatedFalseForADataPush() {
    #expect(!PushPayload.isPropagated(userInfo([a.base64EncodedString()])))
}

@Test func pushPayloadRejectsTooManyPackets() {
    let nine = Array(repeating: a.base64EncodedString(), count: 9)
    #expect(throws: PushPayload.DecodeError.tooManyPackets) {
        try PushPayload.decode(userInfo(nine))
    }
}
