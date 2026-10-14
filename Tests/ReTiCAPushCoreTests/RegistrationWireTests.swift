import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

private let token = Data([0xAA, 0xBB, 0xCC, 0xDD])
private let hash16 = Data(repeating: 0x5A, count: 16)

private func encoded(_ pairs: [MsgPackValue.Pair]) -> Data { MsgPack.encode(.map(pairs)) }

@Test func registrationWireRegisterRequestEncodesTheContractMap() {
    let data = RegistrationWire.registerRequest(token: token, environment: .sandbox, bundleID: "co.example.app")
    #expect(MsgPack.decodeValue(data) == .map([
        .init("v", .uint(1)),
        .init("token", .bin(token)),
        .init("environment", .string("sandbox")),
        .init("bundle_id", .string("co.example.app")),
    ]))
}

@Test func registrationWireUnregisterRequestIsVersionOnly() {
    #expect(MsgPack.decodeValue(RegistrationWire.unregisterRequest()) == .map([.init("v", .uint(1))]))
}

@Test func registrationWireNilAndDefaultAspectsOmitTheKey() {
    let literal: MsgPackValue = .map([
        .init("v", .uint(1)),
        .init("token", .bin(token)),
        .init("environment", .string("sandbox")),
        .init("bundle_id", .string("b")),
    ])
    for aspects in [nil, ["lxmf", "delivery"]] as [[String]?] {
        let data = RegistrationWire.registerRequest(token: token, environment: .sandbox, bundleID: "b", aspects: aspects)
        #expect(MsgPack.decodeValue(data) == literal)
        #expect(MsgPack.decodeValue(RegistrationWire.unregisterRequest(aspects: aspects)) == .map([.init("v", .uint(1))]))
    }
}

@Test func registrationWireRegisterRequestCarriesNonDefaultAspects() {
    let data = RegistrationWire.registerRequest(token: token, environment: .production, bundleID: "b",
                                                aspects: ["nbhd", "sync"])
    #expect(MsgPack.decodeValue(data) == .map([
        .init("v", .uint(1)),
        .init("token", .bin(token)),
        .init("environment", .string("production")),
        .init("bundle_id", .string("b")),
        .init("aspects", .array([.string("nbhd"), .string("sync")])),
    ]))
}

@Test func registrationWireUnregisterRequestCarriesNonDefaultAspects() {
    #expect(MsgPack.decodeValue(RegistrationWire.unregisterRequest(aspects: ["nbhd", "sync"])) == .map([
        .init("v", .uint(1)),
        .init("aspects", .array([.string("nbhd"), .string("sync")])),
    ]))
}

@Test func registrationWireDecodesARegisteredResponse() {
    let data = encoded([.init("ok", .bool(true)), .init("destination_hash", .bin(hash16)), .init("expires_at", .uint(1_702_592_000))])
    #expect(RegistrationWire.decodeResponse(data) == .registered(destinationHash: hash16, expiresAt: 1_702_592_000))
}

@Test func registrationWireDecodesAnUnregisteredResponse() {
    #expect(RegistrationWire.decodeResponse(encoded([.init("ok", .bool(true))])) == .unregistered)
}

@Test func registrationWireDecodesARefusal() {
    let data = encoded([.init("ok", .bool(false)), .init("error", .string("rate_limited"))])
    #expect(RegistrationWire.decodeResponse(data) == .refused(code: "rate_limited"))
}

@Test func registrationWireRejectsMalformed() {
    #expect(RegistrationWire.decodeResponse(Data([0x01, 0x02, 0x03])) == .malformed)
    let shortHash = encoded([.init("ok", .bool(true)), .init("destination_hash", .bin(Data(repeating: 1, count: 5))), .init("expires_at", .uint(1))])
    #expect(RegistrationWire.decodeResponse(shortHash) == .malformed)
    #expect(RegistrationWire.decodeResponse(encoded([.init("ok", .bool(false))])) == .malformed)
}
