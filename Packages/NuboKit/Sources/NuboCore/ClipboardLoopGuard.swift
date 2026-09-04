import CryptoKit
import Foundation

public actor ClipboardLoopGuard {
    private let expiration: Duration
    private let clock = ContinuousClock()
    private var recentlyApplied: [Data: ContinuousClock.Instant] = [:]

    public init(expiration: Duration = .seconds(3)) {
        self.expiration = expiration
    }

    public func markRemoteText(_ text: String) {
        prune()
        recentlyApplied[digest(text)] = clock.now
    }

    public func shouldSendLocalText(_ text: String) -> Bool {
        prune()
        return recentlyApplied.removeValue(forKey: digest(text)) == nil
    }

    private func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    private func prune() {
        recentlyApplied = recentlyApplied.filter { clock.now - $0.value < expiration }
    }
}
