import Foundation

/// One registration attempt over a Reticulum link, as a pure state machine (spec amendment A2).
/// The host app feeds it endpoint events and executes the commands it returns; nothing here
/// knows about TCA or the node, so the whole protocol is testable event by event.
public struct RegistrationLinkFlow: Equatable, Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case hubUnreachable
        case linkFailed
        case requestFailed
        case timedOut
        case cancelled
    }

    public enum Event: Equatable, Sendable {
        /// Begin an attempt. `hubKnown` is whether the transport already has a path to `hub`.
        case start(hub: Data, path: String, data: Data, hubKnown: Bool)
        case pathLearned(Data)
        case linkEstablished(linkID: Data, destinationHash: Data)
        case linkFailed(destinationHash: Data)
        case linkClosed(linkID: Data)
        case responseReceived(linkID: Data, data: Data)
        case requestFailed(linkID: Data)
        case timedOut
        case cancel
    }

    public enum Command: Equatable, Sendable {
        case requestPath(Data)
        case openLink(Data)
        case identify(linkID: Data)
        case sendRequest(linkID: Data, path: String, data: Data)
        case closeLink(linkID: Data)
        case finished(Result<Data, Failure>)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case awaitingPath
        case awaitingLink
        case awaitingResponse(linkID: Data)
    }

    var phase: Phase = .idle
    var hub = Data()
    var path = ""
    var data = Data()
    /// Hubs whose link was still opening when the attempt was abandoned, including a restart to
    /// the SAME hub: ReTiCA mints a new link per `openLink`, so two opens to one hub are two
    /// links, and the first to establish must still be closed. A link that establishes for one of
    /// these hubs is closed on arrival.
    var staleLinkHubs: Set<Data> = []

    public init() {}

    public var isActive: Bool { phase != .idle }

    public mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case let .start(newHub, newPath, newData, hubKnown):
            if phase == .awaitingLink {
                staleLinkHubs.insert(hub)
            }
            var commands = abandon(.cancelled)
            hub = newHub
            path = newPath
            data = newData
            if hubKnown {
                phase = .awaitingLink
                commands.append(.openLink(newHub))
            } else {
                phase = .awaitingPath
                commands.append(.requestPath(newHub))
            }
            return commands

        case let .pathLearned(destination):
            guard phase == .awaitingPath, destination == hub else { return [] }
            phase = .awaitingLink
            return [.openLink(hub)]

        case let .linkEstablished(linkID, destination):
            if staleLinkHubs.remove(destination) != nil { return [.closeLink(linkID: linkID)] }
            guard phase == .awaitingLink, destination == hub else { return [] }
            phase = .awaitingResponse(linkID: linkID)
            return [.identify(linkID: linkID), .sendRequest(linkID: linkID, path: path, data: data)]

        case let .linkFailed(destination):
            if staleLinkHubs.remove(destination) != nil { return [] }
            guard phase == .awaitingLink, destination == hub else { return [] }
            return abandon(.linkFailed)

        case let .linkClosed(linkID):
            guard case let .awaitingResponse(active) = phase, active == linkID else { return [] }
            // The link is already gone: nothing to close.
            phase = .idle
            return [.finished(.failure(.linkFailed))]

        case let .responseReceived(linkID, response):
            guard case let .awaitingResponse(active) = phase, active == linkID else { return [] }
            phase = .idle
            return [.closeLink(linkID: linkID), .finished(.success(response))]

        case let .requestFailed(linkID):
            guard case let .awaitingResponse(active) = phase, active == linkID else { return [] }
            return abandon(.requestFailed)

        case .timedOut:
            guard phase != .idle else { return [] }
            if phase == .awaitingLink { staleLinkHubs.insert(hub) }
            return abandon(phase == .awaitingPath ? .hubUnreachable : .timedOut)

        case .cancel:
            guard phase != .idle else { return [] }
            if phase == .awaitingLink { staleLinkHubs.insert(hub) }
            return abandon(.cancelled)
        }
    }

    /// Close any open link and report `failure`, then go idle. No commands when already idle.
    private mutating func abandon(_ failure: Failure) -> [Command] {
        var commands: [Command] = []
        if case let .awaitingResponse(linkID) = phase {
            commands.append(.closeLink(linkID: linkID))
        }
        if phase != .idle {
            commands.append(.finished(.failure(failure)))
        }
        phase = .idle
        return commands
    }
}
