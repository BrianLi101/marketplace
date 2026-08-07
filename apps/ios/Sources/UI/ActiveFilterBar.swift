import SwiftUI

/// What the results on screen are actually filtered by, stated rather than
/// counted.
///
/// The toolbar's filter button carries a dot when anything is narrowing the
/// results, which answers "is something on?" and nothing else. That is the
/// wrong question: a result set that looks thin is usually thin for a *reason*,
/// and the reason was two taps away inside a sheet.
///
/// So the two things that shape every search — where, and in what order — get
/// permanent readouts, and every other active filter appears as a chip that can
/// be removed where it is read. Nothing hides behind a badge.
struct ActiveFilterBar: View {
    @EnvironmentObject private var prefs: Preferences

    /// Opens the location picker.
    let onLocation: () -> Void
    /// Called after a change Facebook applies server-side, which needs a fresh
    /// search. Client-side filters don't call it — see `Chip.needsRerun`.
    let onRerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                locationReadout
                sortReadout
            }
            if !chips.isEmpty {
                chipRow
            }
        }
        .padding(.horizontal, 16)
        // Tight to the search field above. The bar reads as belonging to it —
        // where, how sorted, what else — so the two want to look like one
        // block rather than two stacked controls with air between them.
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - Readouts

    private var locationReadout: some View {
        Button(action: onLocation) {
            readout(caption: "LOCATION", value: locationValue)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Location, \(locationValue). Change")
    }

    /// A menu rather than a route into the filter sheet: sorting is one of two
    /// things people change constantly, and it should cost one tap.
    private var sortReadout: some View {
        Menu {
            ForEach(SearchQuery.Sort.allCases, id: \.self) { option in
                Button {
                    guard option != prefs.sort else { return }
                    prefs.sort = option
                    onRerun()
                } label: {
                    if option == prefs.sort {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            readout(caption: "SORT", value: prefs.sort.label)
        }
        // A `Menu` tints its label with the accent colour, which made the two
        // halves of the bar look like different kinds of thing — one a value,
        // one a link — when they are the same kind of control.
        .tint(Color.primary)
        .accessibilityLabel("Sort, \(prefs.sort.label). Change")
    }

    /// Caption above value, both always legible. The caption is what makes the
    /// pair readable at a glance — two bare strings side by side don't say
    /// which is the place and which is the order.
    private func readout(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    /// The radius lives here rather than in a chip of its own.
    ///
    /// "San Francisco · 10 mi" is one fact — the catchment — and splitting it
    /// across a readout and a removable chip invites the reading that they are
    /// two separate filters that could disagree.
    private var locationValue: String {
        let place = prefs.locationName ?? "Choose a location"
        guard prefs.radiusKM > 0 else { return place }
        return "\(place) · \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi"
    }

    // MARK: - Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    chipView(chip)
                }
                Button("Clear all") {
                    // Radius and location are deliberately untouched: they are
                    // the readouts above, not chips, and wiping the place a
                    // user chose because they cleared a price filter would be
                    // its own bug.
                    let neededRerun = chips.contains { $0.needsRerun }
                    for chip in chips { chip.clear() }
                    if neededRerun { onRerun() }
                }
                .font(.footnote)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 1)    // keeps focus rings from clipping
        }
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 5) {
            Text(chip.label)
                .font(.footnote.weight(.medium))
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            chip.clear()
            if chip.needsRerun { onRerun() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.label). Remove")
        .accessibilityAddTraits(.isButton)
    }

    private struct Chip: Identifiable {
        let id: String
        let label: String
        /// Whether removing it costs a fresh search. Price, condition and
        /// delivery are applied by Facebook; "only new" is applied here, so
        /// clearing it should not spend a page load.
        let needsRerun: Bool
        let clear: () -> Void
    }

    private var chips: [Chip] {
        var chips: [Chip] = []

        if prefs.minPrice != nil || prefs.maxPrice != nil {
            chips.append(Chip(id: "price", label: priceLabel, needsRerun: true) {
                prefs.minPrice = nil
                prefs.maxPrice = nil
            })
        }
        for condition in prefs.conditions {
            chips.append(Chip(id: "condition-\(condition.rawValue)",
                              label: condition.label, needsRerun: true) {
                prefs.conditions.removeAll { $0 == condition }
            })
        }
        if let delivery = deliveryLabel {
            chips.append(Chip(id: "delivery", label: delivery, needsRerun: true) {
                prefs.delivery = .localPickup
            })
        }
        if prefs.hideViewed {
            chips.append(Chip(id: "viewed", label: "Only new", needsRerun: false) {
                prefs.hideViewed = false
            })
        }
        return chips
    }

    /// Nil for the default. `Delivery` carries no display name of its own —
    /// the filter sheet labels its own pills inline — so the wording lives here
    /// rather than being invented twice.
    private var deliveryLabel: String? {
        switch prefs.delivery {
        case .localPickup: nil
        case .shipping: "Shipping"
        case .any: "Any delivery"
        }
    }

    private var priceLabel: String {
        switch (prefs.minPrice, prefs.maxPrice) {
        case let (min?, max?): "$\(min)–$\(max)"
        case let (nil, max?): "Under $\(max)"
        case let (min?, nil): "Over $\(min)"
        default: "Any price"
        }
    }
}
