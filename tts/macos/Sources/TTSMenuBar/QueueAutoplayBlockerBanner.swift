import SwiftUI

struct QueueAutoplayBlockerBanner: View {
    let blockers: [QueueAutoplayBlocker]

    var body: some View {
        if !blockers.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("QUEUE AUTOPLAY BLOCKED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.orange)

                ForEach(blockers) { blocker in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: blocker.symbol)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(blocker.shortLabel)
                            .font(.caption.weight(.semibold))
                        Text(blocker.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.09))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Queue autoplay blocked")
            .accessibilityValue(QueueAutoplayBlockerPolicy.summary(blockers))
        }
    }
}

extension View {
    func queueAutoplayBlockerBanner(_ blockers: [QueueAutoplayBlocker]) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            QueueAutoplayBlockerBanner(blockers: blockers)
        }
    }
}
