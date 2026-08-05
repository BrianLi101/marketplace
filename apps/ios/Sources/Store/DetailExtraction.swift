import Foundation

/// An item page's fields exactly as `WebLiteScripts.extractDetail` returns
/// them, plus the mapping into the model.
///
/// Two engines produce this now. The feed webview harvests it in place after a
/// tap — WebLite routes the tap client-side and the whole page is in the DOM
/// milliseconds later — and `DetailEngine` loads the page separately for cards
/// the tap can't reach. Neither owns the shape, so it lives here.
struct RawDetail: Decodable {
    let itemId: String?
    let sellerName: String?
    let sellerJoined: String?
    let sellerRatingText: String?
    let sellerRatingCount: String?
    let description: String?
    let photoURLs: [String]
    let postedText: String?
    let conditionText: String?
    let locationText: String?
    let latitude: String?
    let longitude: String?
    let loginWall: Bool

    /// "Has something worth showing" and "has everything" are different
    /// questions, and the gap between them is seconds: the description lands
    /// well before the gallery resolves. Waiting for both before rendering
    /// anything is what made the screen feel slower than it was.
    var hasText: Bool { description != nil }
    var isComplete: Bool { description != nil && !photoURLs.isEmpty }

    var listingDetail: ListingDetail {
        ListingDetail(
            description: description,
            photoURLs: photoURLs.compactMap(URL.init(string:)),
            postedText: postedText,
            conditionText: conditionText,
            locationText: locationText,
            sellerName: sellerName,
            sellerJoined: sellerJoined,
            sellerRating: sellerRatingText.flatMap(Double.init),
            sellerRatingCount: sellerRatingCount.flatMap(Int.init),
            latitude: latitude.flatMap(Double.init),
            longitude: longitude.flatMap(Double.init)
        )
    }

    /// The id the page reports for itself, from `location.pathname`. A redirect,
    /// a wall or Marketplace's own landing page all render and extract cleanly,
    /// so every consumer checks this against the id it asked for.
    func matches(_ expectedID: String?) -> Bool {
        guard let expectedID else { return true }
        return itemId == expectedID
    }
}

extension URL {
    /// The listing id out of a `/marketplace/item/{id}/` path.
    var marketplaceItemID: String? {
        pathComponents.first { $0.count > 8 && $0.allSatisfy(\.isNumber) }
    }
}
