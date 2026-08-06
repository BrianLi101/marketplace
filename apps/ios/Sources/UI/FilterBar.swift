import SwiftUI

/// A city Facebook will accept in a search path.
///
/// Location is the one thing that genuinely moves a result set — it is a path
/// segment, and it works on both surfaces. Everything else about location is
/// decorative: `latitude`/`longitude` are discarded in favour of the
/// IP-inferred place, and `radius` doesn't filter anywhere
/// (`docs/filter-parameters.md`).
struct MarketplaceCity: Identifiable, Hashable {
    let name: String
    let slug: String
    var id: String { slug }

    /// Slugs verified to relocate the result set rather than merely the header.
    /// Cities without a vanity slug need a numeric place id, which is why this
    /// is a curated list rather than a free-text field.
    static let common: [MarketplaceCity] = [
        MarketplaceCity(name: "San Francisco", slug: "sanfrancisco"),
        MarketplaceCity(name: "Oakland", slug: "oakland"),
        MarketplaceCity(name: "Berkeley", slug: "berkeley"),
        MarketplaceCity(name: "San Jose", slug: "sanjose"),
        MarketplaceCity(name: "Daly City", slug: "dalycity"),
        MarketplaceCity(name: "Palo Alto", slug: "paloalto"),
        MarketplaceCity(name: "Fremont", slug: "fremont"),
        MarketplaceCity(name: "Marin", slug: "marin"),
        MarketplaceCity(name: "Los Angeles", slug: "la"),
        MarketplaceCity(name: "New York", slug: "nyc"),
        MarketplaceCity(name: "Seattle", slug: "seattle"),
        MarketplaceCity(name: "Chicago", slug: "chicago")
    ]

    static func named(_ slug: String?) -> MarketplaceCity? {
        guard let slug else { return nil }
        return common.first { $0.slug == slug }
    }
}

/// The filter row above the results.
///
/// Three of these four are applied by Facebook, server-side, so changing them
/// re-runs the search. **Distance is the exception** — no surface honours the
/// `radius` parameter, so it filters the results already on screen against
/// geocoded city centroids. That difference is deliberately visible in the
/// wording ("within N mi" rather than a promise about the search).
struct FilterBar: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: ListingStore

    /// Re-runs the search. Only the server-side filters need it.
    var onServerFilterChange: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                locationMenu
                distanceMenu
                deliveryMenu
                sortMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var locationMenu: some View {
        Menu {
            ForEach(MarketplaceCity.common) { city in
                Button {
                    guard city.slug != prefs.locationSlug else { return }
                    prefs.locationSlug = city.slug
                    prefs.locationName = city.name
                    onServerFilterChange()
                } label: {
                    if city.slug == prefs.locationSlug {
                        Label(city.name, systemImage: "checkmark")
                    } else {
                        Text(city.name)
                    }
                }
            }
        } label: {
            chip(MarketplaceCity.named(prefs.locationSlug)?.name
                 ?? prefs.locationName
                 ?? "San Francisco",
                 icon: "mappin.and.ellipse",
                 isActive: true)
        }
    }

    private var distanceMenu: some View {
        Menu {
            Button {
                prefs.radiusKM = 0
            } label: {
                distanceRow(label: "Any distance", km: 0)
            }
            ForEach(Preferences.radiusOptions, id: \.self) { km in
                Button {
                    prefs.radiusKM = km
                } label: {
                    distanceRow(label: "Within \(SearchQuery.kilometresToMiles(km)) mi", km: km)
                }
            }
            // Says out loud that this one is ours, because it behaves
            // differently from its neighbours: it narrows what is on screen
            // rather than what was asked for, and it can only be as good as a
            // city centroid.
            Section {
                Text("Filtered on this device — Facebook ignores distance in a search.")
            }
        } label: {
            chip(prefs.radiusKM == 0
                 ? "Any distance"
                 : "\(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi",
                 icon: "location.circle",
                 isActive: prefs.radiusKM != 0)
        }
    }

    @ViewBuilder
    private func distanceRow(label: String, km: Int) -> some View {
        if km == prefs.radiusKM {
            Label(label, systemImage: "checkmark")
        } else {
            Text(label)
        }
    }

    private var deliveryMenu: some View {
        Menu {
            deliveryOption(.localPickup, "Local pickup")
            deliveryOption(.any, "Any delivery")
            deliveryOption(.shipping, "Shipping only")
        } label: {
            chip(deliveryLabel, icon: "shippingbox", isActive: prefs.delivery != .any)
        }
    }

    private var deliveryLabel: String {
        switch prefs.delivery {
        case .localPickup: return "Local pickup"
        case .shipping: return "Shipping"
        case .any: return "Any delivery"
        }
    }

    @ViewBuilder
    private func deliveryOption(_ value: SearchQuery.Delivery, _ label: String) -> some View {
        Button {
            guard value != prefs.delivery else { return }
            prefs.delivery = value
            onServerFilterChange()
        } label: {
            if value == prefs.delivery {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            sortOption(.bestMatch)
            sortOption(.nearest)
            sortOption(.newest)
            sortOption(.priceLowest)
            sortOption(.priceHighest)
        } label: {
            chip(prefs.sort.label, icon: "arrow.up.arrow.down",
                 isActive: prefs.sort != .bestMatch)
        }
    }

    @ViewBuilder
    private func sortOption(_ value: SearchQuery.Sort) -> some View {
        Button {
            guard value != prefs.sort else { return }
            prefs.sort = value
            onServerFilterChange()
        } label: {
            if value == prefs.sort {
                Label(value.label, systemImage: "checkmark")
            } else {
                Text(value.label)
            }
        }
    }

    private func chip(_ text: String, icon: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.subheadline)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(isActive
                           ? Color.accentColor.opacity(0.12)
                           : Color(.secondarySystemBackground))
        )
    }
}
