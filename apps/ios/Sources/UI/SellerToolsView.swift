import SwiftUI
import UIKit

/// The Seller tab: describe what you're selling, and get a price backed by what
/// is actually listed nearby, plus a title and description to paste in.
///
/// The screen is built as a **transcript** rather than a form that fills in.
/// Four things happen — a search term is worked out, the market is searched,
/// the prices are read, the listing is written — and they take a few seconds
/// between them. Naming each one as it happens is not decoration: the whole
/// claim this feature makes is "this price comes from real listings near you",
/// and a spinner followed by a number asks the user to take that on faith.
/// Watching it go and look is the evidence.
///
/// The comparables are on screen *above* the recommendation for the same
/// reason. They are the working, not an illustration.
struct SellerToolsView: View {
    @EnvironmentObject private var model: SellerToolsModel
    @FocusState private var isTyping: Bool
    @State private var selected: Listing?
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    prompt
                    if !model.steps.isEmpty { transcript }
                    if !model.comps.isEmpty { comparables }
                    if !model.draft.isEmpty { draftFields }
                    if let notice = model.writingNotice { noticeCard(notice) }
                    if case .failed(let message) = model.phase { failureCard(message) }
                    if model.phase == .done { startOver }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 60)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Seller")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: heroNamespace)
            }
            // The model takes a moment to load the first time. Doing it while
            // the user is still typing means the draft starts the instant they
            // ask for it rather than after it.
            .task { model.prewarm() }
        }
    }

    // MARK: - Asking

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("AI Seller Tools", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                Text("Describe what you're selling. This looks at what similar things are listed for in \(model.marketName), then prices it and writes the listing — all on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("A white IKEA Malm dresser, six drawers, a few scratches on top",
                      text: $model.input,
                      axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .focused($isTyping)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Button {
                isTyping = false
                model.start()
            } label: {
                HStack(spacing: 8) {
                    if model.phase.isRunning {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(model.phase.isRunning ? "Analysing the market…" : "Analyse the market")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase.isRunning || model.input.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
        }
    }

    // MARK: - The transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(for: step.state)
                        .frame(width: 16)
                    Text(step.text)
                        .font(.subheadline)
                        .foregroundStyle(step.state == .running ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func marker(for state: SellerToolsModel.Step.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - The evidence

    private var comparables: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's listed nearby")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.comps) { comp in
                        CompCard(comp: comp)
                            .onTapGesture { selected = comp.listing }
                    }
                }
                .padding(.horizontal, 2)
            }
            // The single most important sentence on this screen. Everything
            // here is what sellers *want*, and Facebook never publishes what
            // buyers paid — so a "market price" built from it is a price the
            // market is being asked for, which is a weaker and different claim.
            Text("Asking prices in \(model.marketName) right now — what sellers want, not what anything sold for.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The draft

    private var draftFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your listing")
                .font(.headline)

            if let title = model.draft.title, !title.isEmpty {
                CopyableField(caption: "TITLE", display: title, copies: title)
            }
            if let price = model.draft.price, price > 0 {
                CopyableField(caption: "PRICE",
                              // Labelled the way the comparables above are —
                              // "CA$80" beside a strip of CA$ cards, never "$80".
                              display: model.guide?.money(price) ?? "\(price)",
                              // Bare, because it is going into Facebook's price
                              // box, which wants a number.
                              copies: String(price),
                              footnote: model.draft.rationale ?? priceFootnote)
            }
            if let body = model.draft.body, !body.isEmpty {
                CopyableField(caption: "DESCRIPTION", display: body, copies: body, isProse: true)
            }
        }
    }

    /// Used when there is no model to explain its own number — the price came
    /// straight from the median, so this says exactly that rather than leaving
    /// a figure with no provenance.
    private var priceFootnote: String? {
        guard let guide = model.guide, guide.count > 0 else { return nil }
        return "The middle of \(guide.count) asking price\(guide.count == 1 ? "" : "s") nearby."
    }

    // MARK: - Endings

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureCard(_ message: String) -> some View {
        InlineNotice(text: message, actionTitle: "Try again") { model.start() }
    }

    private var startOver: some View {
        Button("Start over", role: .destructive) { model.reset() }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
    }
}

/// A field the user is going to paste somewhere else, so copying is the
/// primary action rather than a long-press away.
private struct CopyableField: View {
    let caption: String
    let display: String
    let copies: String
    var footnote: String?
    var isProse = false

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(display)
                        .font(isProse ? .subheadline : .headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "\(caption) copied" : "Copy \(caption.lowercased())")
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func copy() {
        UIPasteboard.general.string = copies
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

/// A comparable at strip size: price first, because price is the only reason
/// this card is on the screen.
private struct CompCard: View {
    let comp: MarketComp

    private static let side: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color(.tertiarySystemFill)
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    AsyncImage(url: comp.listing.thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if comp.isSold { soldTag }
                }
            Text(comp.listing.priceText ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(comp.isSold ? .secondary : .primary)
            if let title = comp.listing.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Marked, not hidden. A sold listing is still worth seeing — it just isn't
    /// worth counting, and `PriceGuide` leaves it out of the arithmetic.
    private var soldTag: some View {
        Text("Sold")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
    }
}
