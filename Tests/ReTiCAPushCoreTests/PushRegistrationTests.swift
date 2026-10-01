import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

private let fixedKey = Data(repeating: 0x11, count: 64)
private let token = Data([0xAA, 0xBB, 0xCC])

private func registration(publicKey: Data = fixedKey, bundleID: String = "co.example.app") -> PushRegistration {
    PushRegistration(publicKey: publicKey, pushToken: token, platform: "ios", environment: .sandbox,
                     bundleID: bundleID, issuedAt: 1_700_000_000)
}

@Test func pushRegistrationSigningBytesMatchTheDocumentedLayout() throws {
    var expected = Data("retica-push-register-v1".utf8)
    expected.append(fixedKey)
    expected.append(contentsOf: [0x00, 0x03])
    expected.append(token)
    expected.append(0x03)
    expected.append(Data("ios".utf8))
    expected.append(0x07)
    expected.append(Data("sandbox".utf8))
    expected.append(0x0E)
    expected.append(Data("co.example.app".utf8))
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x65, 0x53, 0xF1, 0x00])
    #expect(try #require(registration().signingBytes(domain: .register)) == expected)
}

@Test func pushRegistrationSignatureVerifies() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    #expect(signed.verify())
}

@Test func pushRegistrationTamperedTokenFailsVerification() throws {
    let me = Identity()
    var signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    signed.registration.pushToken = Data([0xAA, 0xBB, 0xCD])
    #expect(!signed.verify())
}

@Test func pushRegistrationUnregisterDomainDoesNotVerifyAsRegister() throws {
    let me = Identity()
    var signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .unregister))
    signed.domain = .register
    #expect(!signed.verify())
}

@Test func pushRegistrationJSONUsesTheContractKeys() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    let object = try #require(try JSONSerialization.jsonObject(with: signed.jsonData()) as? [String: Any])
    #expect(Set(object.keys) == ["v", "identity_public_key", "push_token", "platform", "environment",
                                 "bundle_id", "issued_at", "signature"])
    #expect(object["v"] as? Int == 1)
    #expect(object["push_token"] as? String == "aabbcc")
    #expect(object["platform"] as? String == "ios")
    #expect(object["environment"] as? String == "sandbox")
    #expect(object["bundle_id"] as? String == "co.example.app")
    #expect(object["issued_at"] as? Int == 1_700_000_000)
    #expect(Data(base64Encoded: try #require(object["identity_public_key"] as? String)) == me.publicKey)
    #expect(Data(base64Encoded: try #require(object["signature"] as? String)) == signed.signature)
}

@Test func pushRegistrationJSONRoundTrips() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .unregister))
    let back = try SignedRegistration.fromJSON(try signed.jsonData(), domain: .unregister)
    #expect(back == signed)
    #expect(back.verify())
}

@Test func pushRegistrationRejectsAnOversizeBundleID() {
    let me = Identity()
    let long = String(repeating: "a", count: 256)
    #expect(registration(publicKey: me.publicKey, bundleID: long).signed(with: me, domain: .register) == nil)
}

@Test func pushRegistrationRejectsAnOversizeToken() {
    let me = Identity()
    var r = registration(publicKey: me.publicKey)
    r.pushToken = Data(repeating: 0, count: 65_536)
    #expect(r.signed(with: me, domain: .register) == nil)
}
