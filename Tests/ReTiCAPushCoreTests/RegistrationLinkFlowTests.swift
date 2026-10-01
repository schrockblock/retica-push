import Testing
import Foundation
@testable import ReTiCAPushCore

private let hub = Data(repeating: 0xA1, count: 16)
private let otherHub = Data(repeating: 0xA2, count: 16)
private let link = Data(repeating: 0xB1, count: 16)
private let otherLink = Data(repeating: 0xB2, count: 16)
private let request = Data("req".utf8)
private let response = Data("resp".utf8)

private func awaitingLink() -> RegistrationLinkFlow {
    var flow = RegistrationLinkFlow()
    _ = flow.handle(.start(hub: hub, path: "/register", data: request, hubKnown: true))
    return flow
}

private func awaitingResponse() -> RegistrationLinkFlow {
    var flow = awaitingLink()
    _ = flow.handle(.linkEstablished(linkID: link, destinationHash: hub))
    return flow
}

@Test func registrationFlowKnownHubOpensALink() {
    var flow = RegistrationLinkFlow()
    #expect(flow.handle(.start(hub: hub, path: "/register", data: request, hubKnown: true)) == [.openLink(hub)])
    #expect(flow.isActive)
}

@Test func registrationFlowUnknownHubRequestsPathThenOpens() {
    var flow = RegistrationLinkFlow()
    #expect(flow.handle(.start(hub: hub, path: "/register", data: request, hubKnown: false)) == [.requestPath(hub)])
    #expect(flow.handle(.pathLearned(otherHub)) == [])
    #expect(flow.handle(.pathLearned(hub)) == [.openLink(hub)])
}

@Test func registrationFlowEstablishedLinkIdentifiesThenRequests() {
    var flow = awaitingLink()
    #expect(flow.handle(.linkEstablished(linkID: link, destinationHash: hub)) == [
        .identify(linkID: link),
        .sendRequest(linkID: link, path: "/register", data: request),
    ])
}

@Test func registrationFlowResponseClosesAndFinishes() {
    var flow = awaitingResponse()
    #expect(flow.handle(.responseReceived(linkID: link, data: response)) == [
        .closeLink(linkID: link),
        .finished(.success(response)),
    ])
    #expect(!flow.isActive)
}

@Test func registrationFlowIgnoresForeignLinksAndDestinations() {
    var flow = awaitingLink()
    #expect(flow.handle(.linkEstablished(linkID: otherLink, destinationHash: otherHub)) == [])
    _ = flow.handle(.linkEstablished(linkID: link, destinationHash: hub))
    #expect(flow.handle(.responseReceived(linkID: otherLink, data: response)) == [])
    #expect(flow.isActive)
}

@Test func registrationFlowLinkFailureFinishesWithFailure() {
    var flow = awaitingLink()
    #expect(flow.handle(.linkFailed(destinationHash: hub)) == [.finished(.failure(.linkFailed))])
    #expect(!flow.isActive)
}

@Test func registrationFlowRequestFailureClosesTheLink() {
    var flow = awaitingResponse()
    #expect(flow.handle(.requestFailed(linkID: link)) == [.closeLink(linkID: link), .finished(.failure(.requestFailed))])
}

@Test func registrationFlowLinkClosedBeforeResponseFails() {
    var flow = awaitingResponse()
    #expect(flow.handle(.linkClosed(linkID: link)) == [.finished(.failure(.linkFailed))])
}

@Test func registrationFlowTimeoutFailsByPhase() {
    var unknown = RegistrationLinkFlow()
    _ = unknown.handle(.start(hub: hub, path: "/register", data: request, hubKnown: false))
    #expect(unknown.handle(.timedOut) == [.finished(.failure(.hubUnreachable))])
    var awaiting = awaitingResponse()
    #expect(awaiting.handle(.timedOut) == [.closeLink(linkID: link), .finished(.failure(.timedOut))])
}

@Test func registrationFlowRestartCancelsThePreviousAttempt() {
    var flow = awaitingResponse()
    #expect(flow.handle(.start(hub: otherHub, path: "/unregister", data: request, hubKnown: true)) == [
        .closeLink(linkID: link),
        .finished(.failure(.cancelled)),
        .openLink(otherHub),
    ])
}

@Test func registrationFlowEventsWhenIdleDoNothing() {
    var flow = RegistrationLinkFlow()
    #expect(flow.handle(.timedOut) == [])
    #expect(flow.handle(.cancel) == [])
    #expect(flow.handle(.pathLearned(hub)) == [])
    #expect(!flow.isActive)
}

@Test func registrationFlowRestartClosesALinkThatEstablishesLate() {
    var flow = awaitingLink()
    _ = flow.handle(.start(hub: otherHub, path: "/register", data: request, hubKnown: true))
    // The old hub's link arrives after the restart: close it, and the new attempt is untouched.
    #expect(flow.handle(.linkEstablished(linkID: otherLink, destinationHash: hub)) == [.closeLink(linkID: otherLink)])
    #expect(flow.isActive)
    #expect(flow.handle(.linkEstablished(linkID: link, destinationHash: otherHub)) == [
        .identify(linkID: link),
        .sendRequest(linkID: link, path: "/register", data: request),
    ])
}

@Test func registrationFlowStaleHubIsForgottenWhenItsLinkFails() {
    var flow = awaitingLink()
    _ = flow.handle(.cancel)
    #expect(flow.handle(.linkFailed(destinationHash: hub)) == [])
    // Forgotten: a later link for that hub is no longer closed on arrival.
    #expect(flow.handle(.linkEstablished(linkID: link, destinationHash: hub)) == [])
}

@Test func registrationFlowSameHubRestartClosesTheFirstLink() {
    // Two openLinks to the same hub are two links: the first to establish is closed, the second is used.
    var flow = awaitingLink()
    _ = flow.handle(.start(hub: hub, path: "/unregister", data: request, hubKnown: true))
    #expect(flow.handle(.linkEstablished(linkID: link, destinationHash: hub)) == [.closeLink(linkID: link)])
    #expect(flow.handle(.linkEstablished(linkID: otherLink, destinationHash: hub)) == [
        .identify(linkID: otherLink),
        .sendRequest(linkID: otherLink, path: "/unregister", data: request),
    ])
}

@Test func registrationFlowTimeoutWhileOpeningClosesTheLateLink() {
    var flow = awaitingLink()
    #expect(flow.handle(.timedOut) == [.finished(.failure(.timedOut))])
    #expect(flow.handle(.linkEstablished(linkID: link, destinationHash: hub)) == [.closeLink(linkID: link)])
}
