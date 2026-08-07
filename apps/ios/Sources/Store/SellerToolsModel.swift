import Foundation
import SwiftUI
import WebKit

/// Everything behind the Seller tab: search the market, read the prices, write
/// the listing.
///
/// Held at app level rather than by the screen, so a draft survives switching
/// to Browse and back. Someone pricing a dresser is very likely to go and look
/// at the dressers.
@MainActor
final class SellerToolsModel: ObservableObject {
    /// One line of the transcript.
    ///
    /// The work is four distinct things — understand, search, price, write —
    /// and each takes long enough to be worth naming. A single spinner for the
    /// whole run would hide that the app went and looked at the actual market,
    /// which is the part worth trusting.
    struct Step: Identifiable, Equatable {
        enum Kind: Hashable { case understand, search, price, write }
        enum State: Equatable { case running, done, failed }

        let kind: Kind
        var text: String
        var state: State

        var id: Kind { kind }
    }

    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [Step] = []
    @Published private(set) var comps: [MarketComp] = []
    @Published private(set) var guide: PriceGuide?
    @Published private(set) var draft = SellerDraft()
    /// What we actually searched for, which is usually not what the user typed.
    /// Shown, because a price guide is only as good as the comparables behind
    /// it and the user is the one who can tell whether we searched sensibly.
    @Published private(set) var searchTerm: String?
    /// Set when the price came from the median rather than from the model, and
    /// says why there is no title or description. Nil when nothing is missing.
    @Published private(set) var writingNotice: String?

    private let search: ComparableSearch
    private let copywriter: ListingCopywriter
    private let prefs: Preferences
    private var task: Task<Void, Never>?

    /// Has to be in the view hierarchy for WebKit to keep rendering it — same
    /// constraint as the browse engines, same fix in `RootView`.
    var webView: WKWebView { search.webView }

    init(search: ComparableSearch? = nil,
         copywriter: ListingCopywriter? = nil,
         prefs: Preferences = .shared) {
        self.search = search ?? ComparableSearch()
        self.copywriter = copywriter ?? ListingCopywriter()
        self.prefs = prefs
    }

    /// Where the comparables come from, for the screen to state up front.
    var marketName: String { prefs.locationName ?? "your area" }

    var writingAvailability: WritingAvailability { copywriter.availability }

    /// Loads the model while the user is still typing, so the draft doesn't pay
    /// for it. Called when the tab appears.
    func prewarm() { copywriter.prewarm() }

    // MARK: - The run

    func start() {
        let item = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.count >= 3 else { return }
        task?.cancel()
        task = Task { await run(item) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase.isRunning { phase = .idle }
    }

    func reset() {
        cancel()
        input = ""
        steps = []
        comps = []
        guide = nil
        draft = SellerDraft()
        searchTerm = nil
        writingNotice = nil
        phase = .idle
    }

    private func run(_ item: String) async {
        steps = []
        comps = []
        guide = nil
        draft = SellerDraft()
        searchTerm = nil
        writingNotice = nil
        phase = .running

        // 1 — what to search for.
        //
        // Separated from the search itself because it can be wrong in a way the
        // user can see and correct: "searching for ikea malm dresser" is
        // checkable, "found 14 listings" is not.
        begin(.understand, "Working out what to search for")
        let term = await copywriter.searchTerm(for: item)
        guard !Task.isCancelled else { return }
        searchTerm = term
        finish(.understand, "Searching for “\(term)”")

        // 2 — the market itself. One page load.
        begin(.search, "Checking what similar things are listed for in \(marketName)")
        let result = await search.comparables(to: term,
                                              citySlug: prefs.locationSlug ?? "sanfrancisco",
                                              radiusKM: prefs.radiusKM)
        guard !Task.isCancelled else { return }
        switch result {
        case .failure(let error):
            fail(.search, Self.message(for: error))
            phase = .failed(Self.message(for: error))
            return
        case .success(let found):
            comps = found
        }
        finish(.search, comps.count == 1
               ? "Found 1 nearby listing to compare against"
               : "Found \(comps.count) nearby listings to compare against")

        // 3 — arithmetic, in Swift, instantly. Its own step anyway: it is a
        // separate claim from "we found some listings", and it is the one that
        // can come back empty when everything found was free or sold.
        begin(.price, "Reading the prices")
        let computed = PriceGuide(comps: comps)
        guide = computed
        finish(.price, Self.summary(of: computed))

        // 4 — the words.
        begin(.write, "Writing your listing")
        let availability = copywriter.availability
        guard availability.isReady else {
            settleWithoutModel(computed, notice: availability.explanation)
            return
        }
        let written = await copywriter.draft(item: item, comps: comps, guide: computed) { [weak self] partial in
            self?.draft = partial
        }
        guard !Task.isCancelled else { return }
        switch written {
        case .success(let finished):
            draft = finished
            // The description is generated by a second call, and it can fail on
            // its own — the title and price are already in hand by then and are
            // kept rather than discarded. Say which half is missing.
            if finished.body?.isEmpty ?? true {
                writingNotice = "The description didn't come back. The title and price above are still from the listings."
                finish(.write, "Titled and priced — no description")
            } else {
                finish(.write, "Draft ready")
            }
            phase = .done
        case .failure(let error):
            settleWithoutModel(computed, notice: Self.message(for: error))
        }
    }

    /// Finishes the run with a price and no words.
    ///
    /// The median is a real recommendation on its own — it is the number the
    /// model would have been steered towards anyway — so a device that can't
    /// write still answers the question the user came with. Saying which part
    /// is missing, and why, beats an empty screen with an error on it.
    private func settleWithoutModel(_ guide: PriceGuide, notice: String) {
        draft.price = guide.median
        draft.rationale = guide.median.map { guide.explanation(for: $0) }
        writingNotice = notice
        if guide.median != nil {
            finish(.write, "Priced from the market — no description written")
        } else {
            fail(.write, "Nothing to price against")
        }
        phase = .done
    }

    // MARK: - Transcript

    private func begin(_ kind: Step.Kind, _ text: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            steps.append(Step(kind: kind, text: text, state: .running))
        }
    }

    private func finish(_ kind: Step.Kind, _ text: String) {
        update(kind) { $0.text = text; $0.state = .done }
    }

    private func fail(_ kind: Step.Kind, _ text: String) {
        update(kind) { $0.text = text; $0.state = .failed }
    }

    private func update(_ kind: Step.Kind, _ change: (inout Step) -> Void) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { change(&steps[index]) }
    }

    // MARK: - Words for things

    /// States the count as well as the band.
    ///
    /// Without it the transcript reads "Found 15 nearby listings" then "Most
    /// are asking $55–$125", and the two lines look like they describe the
    /// same fifteen when the guide was built from fourteen — one was free, or
    /// sold, or had no readable price. Saying both numbers makes the drop
    /// visible instead of leaving a discrepancy for the user to find.
    static func summary(of guide: PriceGuide) -> String {
        guard guide.count > 0 else { return "None of them had a price to compare" }
        if let range = guide.typicalRange {
            return "\(guide.count) prices — most asking \(guide.money(range.lowerBound))–\(guide.money(range.upperBound))"
        }
        if let median = guide.median {
            return guide.count == 1
                ? "Only one to go on, at \(guide.money(median))"
                : "\(guide.count) prices, around \(guide.money(median))"
        }
        return "None of them had a price to compare"
    }

    static func message(for error: ComparableSearch.Failure) -> String {
        switch error {
        case .loginWall:
            return "Facebook won't show these results without a login. Sign in on the Browse tab and try again."
        case .nothingFound:
            return "Nothing similar is listed nearby, so there's no market to price against."
        case .engine(let message):
            return message
        }
    }

    static func message(for error: ListingCopywriter.Failure) -> String {
        switch error {
        case .unavailable(let availability):
            return availability.explanation
        case .refused:
            return "The on-device writer wouldn't write this one — it can baulk at descriptions with words run together. Try rewording it. The price above still comes from the listings."
        case .failed:
            // Names the likeliest cause, because it is by far the likeliest
            // and the only one the user can do anything about. Apple's
            // `availability` reports `.available` on the strength of Apple
            // Intelligence being switched on, *before* the 3B model asset has
            // finished downloading — measured in the iOS 26 simulator, which
            // reports available and then fails every generation with
            // `ModelManagerError 1026` against an asset whose version is
            // `(none)`. There is no API that distinguishes "enabled" from
            // "downloaded", so the app cannot check for this in advance.
            return "The on-device writer isn't responding. If Apple Intelligence was switched on recently, its model may still be downloading. The price above still comes from the listings."
        }
    }
}
