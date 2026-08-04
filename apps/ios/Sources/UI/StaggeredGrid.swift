import SwiftUI

/// §3.1 — a two-column staggered grid. `LazyVGrid` can't stagger (rows align to
/// the tallest cell), so columns are balanced manually by running height.
struct StaggeredGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { column in
                LazyVStack(spacing: spacing) {
                    ForEach(distribute()[column]) { item in
                        content(item)
                    }
                }
            }
        }
    }

    /// Cells have no measured height yet, so approximate: assume equal heights
    /// and alternate. Good enough visually and stable as items append.
    private func distribute() -> [[Item]] {
        var buckets = Array(repeating: [Item](), count: columns)
        for (index, item) in items.enumerated() {
            buckets[index % columns].append(item)
        }
        return buckets
    }
}

struct SkeletonGrid: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<2, id: \.self) { column in
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { row in
                        SkeletonCard(height: (row + column) % 2 == 0 ? 210 : 170)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct SkeletonCard: View {
    let height: CGFloat
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemFill))
                .frame(height: height)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 60, height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.tertiarySystemFill))
                .frame(height: 12)
        }
        .opacity(shimmer ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}
