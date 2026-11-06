import SwiftUI
import WidgetKit

struct LiveActivityBGLabelWatchView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        HStack {
            Text(context.state.bg)
                .font(.callout)
                .fontWeight(.bold)
                .foregroundStyle(context.isStale ? .secondary : context.state.glucoseTextColor(fallback: glucoseColor))
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            if let trendArrow = context.state.direction {
                Text(trendArrow)
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundStyle(
                        context.isStale ? .secondary : context.state
                            .trendColor(fallback: context.state.glucoseTextColor(fallback: glucoseColor))
                    )
                    .padding(.leading, -5)
            }

            Text(context.state.change)
                .font(.callout)
                .foregroundStyle(
                    context.isStale ? .secondary : context.state
                        .trendColor(fallback: context.state.glucoseTextColor(fallback: glucoseColor))
                )
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            Spacer()

            Text("\((context.state.date != nil) ? dateFormatter.string(from: context.state.date!) : "--")")
                .font(.callout)
                .foregroundStyle(context.isStale ? .red.opacity(0.6) : context.state.elementColor(.updated))
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
        }
    }
}
