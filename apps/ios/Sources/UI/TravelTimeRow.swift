import SwiftUI
import CoreLocation

/// "How long to go get it?", under the map.
///
/// Deliberately behind a tap rather than computed on appear. Routing is a
/// rate-limited network call, and the question is one a user asks about the one
/// listing they're seriously considering — not about all forty they scrolled
/// past. One tap, all three modes.
///
/// Appears only when the device has an actual fix. Everything else on this
/// screen degrades gracefully without one; a travel time cannot, because there
/// would be nowhere to travel *from*. The chosen search city is not a
/// substitute: it says which listings Facebook returns, not where the user is.
struct TravelTimeRow: View {
    let destination: CLLocationCoordinate2D
    let precision: LocationMapCard.Precision

    @EnvironmentObject private var location: LocationProvider
    @StateObject private var travel = MapKitTravelTime.shared
    @State private var didAsk = false

    var body: some View {
        if let origin = location.coordinate {
            VStack(alignment: .leading, spacing: 8) {
                if didAsk {
                    modes
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        didAsk = true
                        Task { await travel.estimateAll(from: origin, to: destination) }
                    } label: {
                        Label("Estimate travel time", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            // A new listing is a new question. Without this the row would stay
            // open, showing the previous listing's answer for a moment.
            .onChange(of: destination.latitude) { didAsk = false }
        }
    }

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
