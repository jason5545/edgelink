public struct SessionLifecycleFence<SessionID: Hashable & Sendable>: Sendable {
    private var activeSessionIDs: Set<SessionID> = []

    public private(set) var generation: UInt64 = 0

    public init() {}

    public var hasActiveSessions: Bool {
        !activeSessionIDs.isEmpty
    }

    public var activeSessionCount: Int {
        activeSessionIDs.count
    }

    public mutating func register(_ sessionID: SessionID) {
        activeSessionIDs.insert(sessionID)
    }

    public mutating func remove(_ sessionID: SessionID) {
        activeSessionIDs.remove(sessionID)
    }

    @discardableResult
    public mutating func reset() -> UInt64 {
        activeSessionIDs.removeAll()
        generation &+= 1
        return generation
    }

    public func shouldHonorStop(from eventGeneration: UInt64) -> Bool {
        eventGeneration == generation && activeSessionIDs.isEmpty
    }
}
