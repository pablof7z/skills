import SwiftUI

enum QuestionIndicatorState: Equatable {
    case pending
    case answered
    case resolved

    init(item: TTSItem) {
        if item.isPendingQuestion {
            self = .pending
        } else if item.questionStatus == .answered {
            self = .answered
        } else {
            self = .resolved
        }
    }

    var systemImage: String {
        self == .answered ? "checkmark.bubble.fill" : "questionmark.bubble.fill"
    }

    var help: String {
        switch self {
        case .pending: "Contains unanswered questions"
        case .answered: "Answered"
        case .resolved: "Contains questions"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pending: "Unanswered questions"
        case .answered: "Answered question"
        case .resolved: "Question"
        }
    }
}

struct QuestionIndicatorView: View {
    enum Size: Equatable {
        case header
        case row
    }

    let item: TTSItem
    let accent: Color
    let size: Size

    private var state: QuestionIndicatorState { QuestionIndicatorState(item: item) }

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundColor)
            .frame(width: dimension, height: dimension)
            .background(backgroundColor, in: Circle())
            .shadow(color: shadowColor, radius: 4, y: 1)
            .help(state.help)
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityHidden(size == .header)
    }

    private var dimension: CGFloat { size == .header ? 42 : 28 }
    private var fontSize: CGFloat { size == .header ? 21 : (state == .pending ? 14 : 13) }
    private var fontWeight: Font.Weight { state == .pending ? .bold : .semibold }

    private var foregroundColor: Color {
        switch (size, state) {
        case (_, .answered): .green
        case (.row, .pending): .white
        case (.row, .resolved): .purple
        case (.header, _): accent
        }
    }

    private var backgroundColor: Color {
        switch (size, state) {
        case (_, .answered): Color.green.opacity(size == .header ? 0.16 : 0.12)
        case (.row, .pending): .orange
        case (.row, .resolved): Color.purple.opacity(0.12)
        case (.header, _): accent.opacity(0.16)
        }
    }

    private var shadowColor: Color {
        size == .row && state == .pending ? Color.orange.opacity(0.28) : .clear
    }
}
