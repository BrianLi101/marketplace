import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import os

/// The listing being drafted, as it fills in.
///
/// One type for both the partial and the finished draft, because a partial is
/// just this with fewer fields. They arrive in this order — title, then price
/// and its explanation, then the description from a second call — and the
/// screen shows each the moment it exists. Nothing downstream has to know
/// whether generation has finished.
struct SellerDraft: Equatable {
    var title: String?
    var price: Int?
    /// Why that price. Written by `PriceGuide`, not by the model — see
    /// `DraftedHeadline`.
    var rationale: String?
    var body: String?

    var isEmpty: Bool { title == nil && price == nil && rationale == nil && body == nil }
}

/// Whether this device can write copy at all, and why not when it can't.
enum WritingAvailability: Equatable {
    case ready
    case needsNewerOS
    case needsAppleIntelligence
    case notReadyYet
    case deviceNotEligible

    var isReady: Bool { self == .ready }

    /// Written for someone who is not going to be told to go and enable a
    /// framework. Each case is a different thing to do, or a different reason
    /// there is nothing to do.
    var explanation: String {
        switch self {
        case .ready:
            return ""
        case .needsNewerOS:
            return "Writing titles and descriptions needs iOS 26. The price guide still works."
        case .needsAppleIntelligence:
            return "Turn on Apple Intelligence in Settings to have titles and descriptions written for you. The price guide still works."
        case .notReadyYet:
            return "Apple Intelligence is still downloading its model. Try again shortly — the price guide already works."
        case .deviceNotEligible:
            return "This device can't run Apple Intelligence, so titles and descriptions aren't available. The price guide still works."
        }
    }
}

/// Writes the listing, on the device.
///
/// Nothing typed here leaves the phone. That is not a bonus feature of the
/// implementation, it is the reason this is Apple's on-device model rather than
/// a hosted one: the input is a description of something in someone's home,
/// alongside what they think it is worth.
///
/// The division of labour with `PriceGuide` is deliberate and holds throughout:
/// **every number is Swift's, every sentence is the model's.** Swift computes
/// the market — median, quartiles, range — hands those figures over, holds the
/// model's answer inside them (`PriceGuide.clamped`), and writes the
/// explanation of where the price sits. The model names the item, picks a point
/// in the range, and writes the description.
///
/// That line was drawn where it is because of what happened on the other side
/// of it. Asked to explain its own figure against fourteen prices it had just
/// been shown, the model wrote "you are asking CA$20 more than the median price
/// of CA$80" — the median was CA$77 and the gap was CA$33. Small models produce
/// arithmetic that reads correctly and isn't, and the one number here that
/// someone will act on is the price.
@MainActor
final class ListingCopywriter {
    enum Failure: Error, Equatable {
        /// No model on this device. Carries the reason so the UI can say it.
        case unavailable(WritingAvailability)
        /// The model declined to write this. Its own safety filter, not ours.
        ///
        /// Reachable in ordinary use, not just on malicious input: a mangled
        /// item description — "WhiteIKEAMalm dressed", produced by a keyboard
        /// swallowing spaces — trips it, where the same words spaced properly
        /// do not. So it gets a real message rather than being folded into a
        /// generic failure.
        case refused
        /// Anything else. Carries no detail on purpose: the framework's own
        /// message is "The operation couldn't be completed.
        /// (FoundationModels.LanguageModelSession.GenerationError error -1.)",
        /// which told the first person to see it precisely nothing. The case
        /// name goes to the log, where it can be acted on.
        case failed
    }

    /// Checked on every run rather than cached: Apple Intelligence can be
    /// switched on, and the model can finish downloading, while the app is open.
    var availability: WritingAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return Self.modelAvailability() }
        #endif
        return .needsNewerOS
    }

    /// Loads the model before it's needed, so the first draft doesn't pay for
    /// it. Called when the seller tab appears — a no-op if the model is already
    /// resident, and harmless if it is never used.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .ready = availability {
            // Any session warms the same underlying model, so the headline
            // one stands in for all three.
            LanguageModelSession(instructions: Self.headlineInstructions).prewarm()
        }
        #endif
    }

    /// Turns what the seller typed into something worth searching for.
    ///
    /// People describe what they're selling; they don't phrase it as a query.
    /// "IKEA Malm 6 drawer dresser, white, barely used, from a pet-free home"
    /// searched literally finds nothing, because no other listing says that.
    /// The model strips it back to the two or three words that identify the
    /// *kind of thing*, which is what the comparables have in common.
    ///
    /// Falls back to a plain heuristic with no model, so the price guide still
    /// works on a device that can't write.
    func searchTerm(for item: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .ready = availability {
            if let term = await Self.generateSearchTerm(for: item) { return term }
        }
        #endif
        return Self.heuristicSearchTerm(for: item)
    }

    /// Drafts the listing, streaming each field as it lands.
    ///
    /// `onUpdate` fires many times — that is the point. A four-second wait on a
    /// spinner and a four-second wait watching a description write itself are
    /// the same four seconds and do not feel remotely alike.
    func draft(item: String,
               comps: [MarketComp],
               guide: PriceGuide,
               onUpdate: @MainActor @escaping (SellerDraft) -> Void) async -> Result<SellerDraft, Failure> {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let availability = availability
            guard case .ready = availability else { return .failure(.unavailable(availability)) }
            return await Self.generateDraft(item: item, comps: comps, guide: guide, onUpdate: onUpdate)
        }
        #endif
        return .failure(.unavailable(.needsNewerOS))
    }

    // MARK: - The prompts
    //
    // Everything below was arrived at by running it, three times per variant,
    // against the real model. The notes say what each rule is holding back,
    // because every one of them is holding back something that was observed.

    /// Naming and pricing, which the model is good at.
    ///
    /// The line about comparables exists because of a specific failure: given a
    /// stroller to name and a page of dressers to price against, the model
    /// titled it "IKEA Malm 4 Drawer Dresser White" on all three runs. The
    /// comps are numerically load-bearing and semantically poisonous, and they
    /// have to be labelled as such.
    ///
    /// The two worked examples are what stopped faults leaking into titles
    /// ("Trek Mountain Bike, 21 Speed, Needs New Brake Pads") and got Title
    /// Case applied consistently. With them, nine of nine runs were clean.
    static let headlineInstructions = """
    You name and price second-hand items for a private seller on Facebook \
    Marketplace. The title must describe the seller's own item. Comparable \
    listings are given to you for pricing only — never take the item's identity \
    from them.

    A title names the thing. It never mentions a fault.
    "Trek mountain bike, 21 speed, needs new brake pads" -> "Trek Mountain Bike, 21 Speed"
    "IKEA Malm dresser in white, six drawers, scratched top" -> "IKEA Malm 6-Drawer Dresser, White"
    """

    /// Writing the description, which the model is bad at, constrained until
    /// it stops being dangerous.
    ///
    /// The long list of banned phrases is not fastidiousness. Without it the
    /// model wrote "a great addition to any bedroom", "a great value for the
    /// price" and "sure to suit anyone" — and, far worse, "the rest of the
    /// dresser is in good condition" about an item whose only stated fact was a
    /// scratched top, and "a few minor scratches on the frame" about a bike
    /// whose seller mentioned no scratches at all. A seller reading copy about
    /// their own belongings is the last person who will notice a plausible
    /// invented detail, and an invented condition claim in a published listing
    /// is somebody's dispute later.
    ///
    /// The "comes with / included" ban has its own history: an earlier example
    /// here ended "The carry case is included", and the model imitated the
    /// *shape* rather than the rule — inventing "comes with the dresser legs",
    /// "comes with a spare tire", "comes with a spare tube". Both examples now
    /// end on "Collection only." so that the safest sentence is the one being
    /// copied.
    ///
    /// **The result is deliberately conservative.** With one line of input a
    /// faithful description cannot contain more than that line, and every
    /// attempt to make it richer made it fabricate: asking for each fault in
    /// its own sentence produced three invented faults for a stroller
    /// described only as "folds flat, barely used". Restating the seller
    /// accurately is a real if modest service; inventing wear on their behalf
    /// is not a service at all.
    static let bodyInstructions = """
    You write the description of a second-hand item for a private seller.

    Write two or three short sentences:
    1. What the item is.
    2. Any fault or wear the seller mentioned, stated plainly and not softened.
    3. "Collection only."

    You may write nothing that the seller did not say. You may not add \
    accessories, extras, spares, cases, parts or anything "included" or "comes \
    with" unless the seller listed it. You may not describe the item's \
    condition, age, cleanliness or history unless the seller did. You may not \
    write that it is in good condition, well cared for, barely used, a great \
    addition, great value, perfect for, ideal for, stylish, functional or \
    reliable. No exclamation marks. No closing pitch. Plain text.

    Example seller description:
    "Sony WH-1000XM4 headphones, one earcup is a bit loose"
    Example output:
    Sony WH-1000XM4 wireless headphones. One earcup is a bit loose. Collection only.

    Example seller description:
    "Round oak dining table, seats four"
    Example output:
    Round oak dining table that seats four. Collection only.
    """

    static func bodyPrompt(item: String) -> String {
        "Seller description: \"\(item)\""
    }

    /// Everything the model is allowed to know about the market, stated once.
    ///
    /// The statistics are handed over already computed, and the recommendation
    /// is bounded to the interquartile range up front, so the model is choosing
    /// within a range rather than picking a number.
    static func headlinePrompt(item: String, comps: [MarketComp], guide: PriceGuide) -> String {
        var lines: [String] = []
        lines.append("The seller is selling: \"\(item)\"")
        lines.append("")

        let priced = comps.filter { !$0.isSold && ($0.price ?? 0) > 0 }
        if priced.isEmpty {
            lines.append("No comparable listings with prices were found nearby.")
            lines.append("Suggest a price only if the item is one whose value is common knowledge; otherwise suggest 0 and say in the rationale that there was nothing nearby to compare against.")
        } else {
            lines.append("Comparable listings nearby right now. These are asking prices, not sale prices, and all figures are in \(guide.currency):")
            for comp in priced.prefix(15) {
                let title = comp.listing.title ?? "Untitled listing"
                lines.append("- \"\(title)\" — \(guide.money(comp.price ?? 0))")
            }
            lines.append("")
            if let median = guide.median, let low = guide.lowest, let high = guide.highest {
                lines.append("Computed from those \(guide.count) asking prices: median \(guide.money(median)), range \(guide.money(low)) to \(guide.money(high)).")
            }
            if let range = guide.typicalRange {
                lines.append("Middle half of the market: \(guide.money(range.lowerBound)) to \(guide.money(range.upperBound)).")
                lines.append("Choose a price between \(range.lowerBound) and \(range.upperBound). Go outside that only if the seller's item is clearly better or worse than the comparables.")
            } else if let median = guide.median {
                lines.append("Too few comparables for a reliable range. Stay near \(median).")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The no-model path. Not clever, and it doesn't need to be: dropping
    /// filler words and keeping the first few content words gets "ikea malm
    /// dresser" out of a sentence about a dresser, which is a searchable term.
    static func heuristicSearchTerm(for item: String) -> String {
        let filler: Set<String> = [
            "a", "an", "the", "my", "our", "i", "im", "am", "is", "are", "was", "for",
            "sale", "selling", "sell", "with", "and", "in", "of", "very", "really",
            "great", "good", "nice", "condition", "used", "new", "barely", "hardly",
            "like", "excellent", "perfect", "mint", "some", "few", "little", "bit",
            "from", "home", "house", "smoke", "pet", "free", "no", "not", "it", "its",
        ]
        let words = item
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
        guard !words.isEmpty else {
            return item.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return words.prefix(4).joined(separator: " ")
    }
}

// MARK: - FoundationModels

#if canImport(FoundationModels)

/// Naming and pricing, in one call.
///
/// Field order is load-bearing: guided generation emits fields in declaration
/// order, so this is also the order they appear on screen — the title lands
/// first and confirms the model understood what is being sold, then the price.
///
/// **There is no `rationale` field here, and that is the point.** There was
/// one, and the model used it to do arithmetic about the sample it had just
/// been given: "you are asking CA$20 more than the median price of CA$80",
/// against a measured median of CA$77. Two wrong numbers in one confident
/// sentence, under the figure a person is about to act on. The explanation is
/// now written by `PriceGuide`, which knows the numbers because it computed
/// them.
@available(iOS 26, *)
@Generable
private struct DraftedHeadline {
    @Guide(description: "How a buyer would search for the seller's item: brand, model, and the one or two attributes that identify it. Title Case. At most 60 characters. Do not restate the seller's whole sentence, do not mention faults or condition, do not include a price.")
    var title: String

    @Guide(description: "The recommended asking price as a whole number in the stated currency. Digits only.")
    var price: Int
}

/// The description, generated on its own.
///
/// Split from the headline because the model drifts once it has produced a few
/// fields — asked for four things at once it wrote clean titles and then
/// slid into advertising copy by the fourth. One narrow task per session held
/// it; the same rules in a combined call did not.
@available(iOS 26, *)
@Generable
private struct DraftedDescription {
    @Guide(description: "The listing description. Two or three sentences, plain text.")
    var body: String
}

@available(iOS 26, *)
@Generable
private struct ExtractedSearchTerm {
    @Guide(description: "A Facebook Marketplace search query of two to five words that would find items of the same kind. Keep brand and model. Drop condition, colour, price, and anything about the seller.")
    var query: String
}

@available(iOS 26, *)
extension ListingCopywriter {
    static func modelAvailability() -> WritingAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .needsAppleIntelligence
            case .modelNotReady: return .notReadyYet
            case .deviceNotEligible: return .deviceNotEligible
            @unknown default: return .deviceNotEligible
            }
        @unknown default:
            return .deviceNotEligible
        }
    }

    static func generateSearchTerm(for item: String) async -> String? {
        let session = LanguageModelSession(instructions: """
        You turn a description of something someone is selling into a short \
        marketplace search query that would find similar items.
        """)
        do {
            let response = try await session.respond(
                to: "Item: \"\(item)\"",
                generating: ExtractedSearchTerm.self,
                options: options
            )
            let query = response.content.query.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        } catch {
            // Falls back to the heuristic rather than failing the run. The
            // transcript shows what was searched for either way, so a worse
            // query is visible to the person best placed to notice it.
            Logger.seller.error("search term: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Low, because the same input should give the same advice.
    ///
    /// At the default, three runs on one dresser returned CA$100, CA$110 and
    /// CA$140. A price recommendation that moves by 40% when you tap the button
    /// again is not a recommendation.
    static let options = GenerationOptions(temperature: 0.3)

    static func generateDraft(item: String,
                              comps: [MarketComp],
                              guide: PriceGuide,
                              onUpdate: @MainActor @escaping (SellerDraft) -> Void) async -> Result<SellerDraft, Failure> {
        var latest = SellerDraft()

        do {
            let session = LanguageModelSession(instructions: headlineInstructions)
            let stream = session.streamResponse(to: headlinePrompt(item: item, comps: comps, guide: guide),
                                                generating: DraftedHeadline.self,
                                                options: options)
            for try await partial in stream {
                latest.title = partial.content.title
                if let price = partial.content.price {
                    latest.price = guide.clamped(price)
                    latest.rationale = guide.explanation(for: guide.clamped(price))
                }
                onUpdate(latest)
            }
        } catch {
            return .failure(classify(error, stage: "headline"))
        }

        // A second call, and a failure here is not a failure of the run: the
        // title and price have already landed and are the harder half of the
        // answer. Throwing them away because the description didn't come back
        // would be the wrong trade.
        do {
            let session = LanguageModelSession(instructions: bodyInstructions)
            let stream = session.streamResponse(to: bodyPrompt(item: item),
                                                generating: DraftedDescription.self,
                                                options: options)
            for try await partial in stream {
                latest.body = partial.content.body
                onUpdate(latest)
            }
        } catch {
            Logger.seller.error("body: \(String(describing: error), privacy: .public)")
        }
        return .success(latest)
    }

    /// `String(describing:)` rather than `localizedDescription`, which is the
    /// same useless sentence for every case — "The operation couldn't be
    /// completed. (FoundationModels.LanguageModelSession.GenerationError error
    /// -1.)" — where this prints the case name and its context.
    ///
    /// Not every failure arrives as a typed `GenerationError`. Some cross the
    /// XPC boundary already bridged to `NSError`, the missing-model-asset one
    /// among them, and the case can't be recovered from those. The distinction
    /// only changes the wording of a notice, so an unrecognised error stays
    /// generic rather than being matched on a localised string, and the whole
    /// thing goes to the log where it can be read.
    private static func classify(_ error: Error, stage: String) -> Failure {
        Logger.seller.error("\(stage, privacy: .public): \(String(describing: error), privacy: .public)")
        if let generation = error as? LanguageModelSession.GenerationError,
           case .guardrailViolation = generation {
            return .refused
        }
        return .failed
    }
}

#endif
