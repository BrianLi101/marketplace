import SwiftUI
import CoreLocation

/// "How long to go get it?", under the map.
///
/// Runs on its own, as soon as there's a point worth routing to. Opening a
/// listing is already the deliberate act — nobody taps into a detail screen by
/// accident — so making the user ask a second time bought nothing.
///
/// What it does wait for is a *settled* destination. The map shows the city
/// centroid until the item page lands and then jumps to the listing's own
/// point, and routing to the centroid first would spend three requests on the
/// wrong place and then visibly rewrite every number under the user. So the
/// trigger is the point, not the screen: a listing already in the cache routes
/// on the first frame, and a cold one routes the moment enrichment settles —
/// including when it settles on failure, where the centroid is all there will
/// ever be.
///
/// Appears only when the device has an actual fix. Everything else on this
/// screen degrades gracefully without one; a travel time cannot, because there
/// would be nowhere to travel *from*. The chosen search city is not a
/// substitute: it says which listings Facebook returns, not where the user is.
struct TravelTimeRow: View {
    let destination: CLLocationCoordinate2D
    let precision: LocationMapCard.Precision
    /// The item page is still in flight, so `destination` may yet be replaced.
    let isEnriching: Bool

    @EnvironmentObject private var location: LocationProvider
    @StateObject private var travel = MapKitTravelTime.shared

    var body: some View {
        if let origin = location.coordinate {
            VStack(alignment: .leading, spacing: 8) {
                modes
                HStack(spacing: 8) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    // Throttling and dropped connections are both transient and
                    // both look identical from here, so the only sensible
                    // response is to offer another go.
                    if anyFailed {
                        Button("Try again") { Task { await run(from: origin) } }
                            .font(.caption)
                    }
                }
            }
            // Keyed on the destination *and* on whether it can still change, so
            // this fires once for a settled point and re-fires if the item page
            // moves it. Same key on return within the freshness window means
            // the cached answer is reused rather than re-requested.
            .task(id: trigger) {
                guard !isEnriching || precision == .listing else { return }
                await run(from: origin)
            }
        }
    }

    private func run(from origin: CLLocationCoordinate2D) async {
        await travel.estimateAll(from: origin, to: destination)
    }

    private var trigger: String {
        "\(destination.latitude),\(destination.longitude),\(isEnriching)"
    }

    private var estimates: [MapKitTravelTime.Estimate] {
        MapKitTravelTime.Mode.allCases.map { travel.estimate(for: destination, mode: $0) ?? .pending }
    }

    private var anyFailed: Bool { estimates.contains(.failed) }

    private var modes: some View {
        HStack(spacing: 8) {
            ForEach(MapKitTravelTime.Mode.allCases) { mode in
                ModeChip(mode: mode, estimate: travel.estimate(for: destination, mode: mode) ?? .pending)
            }
        }
    }

    /// Says which of two very different points the estimate was measured to —
    /// the same distinction the map's circle is drawing above it.
    private var caption: String {
        switch precision {
        case .listing: "Estimated to the approximate area, from your location"
        case .city: "Estimated to the city centre — the listing's own point isn't known yet"
        }
    }
}

private struct ModeChip: View {
    let mode: MapKitTravelTime.Mode
    let estimate: MapKitTravelTime.Estimate

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: mode.symbol)
                .font(.subheadline)
            value
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(isKnown ? .primary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var value: some View {
        switch estimate {
        case .pending: ProgressView().controlSize(.mini)
        case .travelTime(let seconds): Text(MapKitTravelTime.format(seconds))
        case .unroutable: Text("No route")
        case .failed: Text("—")
        }
    }

    private var isKnown: Bool {
        if case .travelTime = estimate { return true }
        return false
    }

    private var accessibilityText: String {
        switch estimate {
        case .pending: "\(mode.label), estimating"
        case .travelTime(let seconds): "\(mode.label), about \(MapKitTravelTime.format(seconds))"
        case .unroutable: "\(mode.label), no route"
        case .failed: "\(mode.label), unavailable"
        }
    }
}
