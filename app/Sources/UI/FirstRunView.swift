import SwiftUI

/// §5 / §7.4 — three cards: what this is, no login required, how handoff works.
/// The no-login promise is the top question users have, and it's true.
struct FirstRunView: View {
    let done: () -> Void
    @State private var page = 0

    private struct Card {
        let symbol: String
        let title: String
        let body: String
    }

    private let cards = [
        Card(symbol: "square.grid.2x2",
             title: "Local listings, fast",
             body: "A clean, quick way to browse what's for sale near you — no feed, no clutter, no ads in the way."),
        Card(symbol: "lock.open",
             title: "No login. Ever.",
             body: "This app browses public listings without signing in. It never asks for your Facebook password, and it can't see your account."),
        Card(symbol: "arrow.up.forward.app",
             title: "Messaging opens Facebook",
             body: "When you want to message a seller, make an offer, or save an item, we hand you to the Facebook app to finish up.")
    ]

    var body: some View {
        VStack {
            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { index in
                    VStack(spacing: 18) {
                        Image(systemName: cards[index].symbol)
                            .font(.system(size: 54))
                            .foregroundStyle(.tint)
                        Text(cards[index].title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(cards[index].body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page)

            Button(page == cards.count - 1 ? "Start browsing" : "Next") {
                if page == cards.count - 1 { done() } else { withAnimation { page += 1 } }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
    }
}
