import Foundation

/// §7.3 — fetch only what the user is looking at, back off hard when Facebook
/// pushes back, and cap the session so a bug can't turn into a crawl.
actor RequestPacer {
    /// The one pacer. Everything that talks to Facebook shares it.
    ///
    /// Each engine used to construct its own, via a `= RequestPacer()` default
    /// argument, which quietly defeated all three mechanisms below. The session
    /// cap became per-engine rather than per-session, so the real ceiling was
    /// some multiple of 300. The minimum gap stopped being a gap, because two
    /// engines could fire simultaneously without seeing each other.
    ///
    /// And worst, **backoff stopped propagating**: Facebook blocking the feed
    /// engine put that one engine on its ladder while the detail engine carried
    /// on at full speed, unaware. Backoff only one code path observes isn't
    /// backoff — §7.3 asks the *session* to go quiet, not one class. That
    /// matters more now that everything shares one cookie jar, because every
    /// request is attributable to the same account.
    static let shared = RequestPacer()

    private var consecutiveBlocks = 0
    private var requestCount = 0
    private var blockedUntil: Date?

    /// 30s → 2m → 10m → stop, per spec.
    private static let backoffLadder: [TimeInterval] = [30, 120, 600]
    private static let sessionRequestCap = 300
    private static let minimumGap: TimeInterval = 0.4
    private var lastRequest: Date?

    var isStopped: Bool { consecutiveBlocks > Self.backoffLadder.count }

    /// Returns false when the caller should not make a request at all.
    func waitForSlot() async -> Bool {
        guard requestCount < Self.sessionRequestCap, !isStopped else { return false }

        if let blockedUntil, blockedUntil > Date() {
            let wait = blockedUntil.timeIntervalSinceNow
            guard wait < 15 else { return false }   // don't hold the UI on a long backoff
            try? await Task.sleep(for: .seconds(wait))
        }
        if let last = lastRequest {
            let gap = Date().timeIntervalSince(last)
            if gap < Self.minimumGap {
                try? await Task.sleep(for: .seconds(Self.minimumGap - gap))
            }
        }
        lastRequest = Date()
        requestCount += 1
        return true
    }

    func recordSuccess() {
        consecutiveBlocks = 0
        blockedUntil = nil
    }

    func recordBlock() {
        let index = min(consecutiveBlocks, Self.backoffLadder.count - 1)
        blockedUntil = Date().addingTimeInterval(Self.backoffLadder[index])
        consecutiveBlocks += 1
    }

    var backoffRemaining: TimeInterval {
        guard let blockedUntil else { return 0 }
        return max(0, blockedUntil.timeIntervalSinceNow)
    }
}
