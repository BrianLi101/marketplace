import Foundation
import os

/// §8. No listing content and no search terms ever leave the device; these are
/// counters and rates only. The protocol exists so a backend can be chosen
/// later without touching call sites — today it logs locally.
protocol MetricsReporter: AnyObject {
    func parseHealth(_ health: ParseHealth)
    func loginWallHit(surface: String)
    func detailLatency(seconds: TimeInterval, succeeded: Bool)
    func handoff(kind: String)
    func pageLoaded(index: Int, listings: Int)
}

struct ParseHealth: Equatable {
    var domCards = 0
    var extracted = 0
    var dropped = 0
    var rendered = 0
    var fieldCounts: [String: Int] = [:]

    func coverage(_ field: String) -> Double {
        guard extracted > 0 else { return 0 }
        return Double(fieldCounts[field] ?? 0) / Double(extracted)
    }

    /// §3.4 flags any field below this.
    static let coverageThreshold = 0.90

    var failingFields: [String] {
        fieldCounts.keys.filter { coverage($0) < Self.coverageThreshold }.sorted()
    }
}

final class LocalMetrics: MetricsReporter {
    static let shared = LocalMetrics()
    private let log = Logger(subsystem: "lol.frens.openmarket", category: "metrics")

    private(set) var latestHealth = ParseHealth()
    private(set) var loginWallCount = 0
    private(set) var sessionRequestCount = 0

    func parseHealth(_ health: ParseHealth) {
        latestHealth = health
        let failing = health.failingFields
        log.info("parse: dom=\(health.domCards) extracted=\(health.extracted) dropped=\(health.dropped) rendered=\(health.rendered) failing=\(failing.joined(separator: ","))")
    }

    func loginWallHit(surface: String) {
        loginWallCount += 1
        log.warning("login wall on \(surface, privacy: .public), total=\(self.loginWallCount)")
    }

    func detailLatency(seconds: TimeInterval, succeeded: Bool) {
        log.info("detail \(succeeded ? "ok" : "failed") in \(String(format: "%.2f", seconds))s")
    }

    func handoff(kind: String) {
        log.info("handoff: \(kind, privacy: .public)")
    }

    func pageLoaded(index: Int, listings: Int) {
        sessionRequestCount += 1
        log.info("page \(index) -> \(listings) listings (session requests: \(self.sessionRequestCount))")
    }
}
