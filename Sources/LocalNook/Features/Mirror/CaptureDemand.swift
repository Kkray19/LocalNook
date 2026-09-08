/// Main-actor capture intent; stale authorization/configuration cannot revive a closed preview.
struct CaptureDemand {
    private(set) var isActive = false
    private var generation = 0
    mutating func activate() { isActive = true; generation += 1 }
    mutating func deactivate() { isActive = false; generation += 1 }
    mutating func nextConfiguration() -> Int { generation += 1; return generation }
    func accepts(_ token: Int) -> Bool { isActive && generation == token }
}
