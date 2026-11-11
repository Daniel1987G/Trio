import SwiftUI
import Swinject

/// Lets the user pick a colour per Live Activity element; "Standard" keeps the built-in look.
struct LiveActivityColorsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: LiveActivitySettings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section {
                preview
            } header: {
                Text("Preview")
            }.listRowBackground(Color.chart)

            Section {
                ForEach(LiveActivityColors.Element.allCases) { element in
                    row(for: element)
                }
            } header: {
                Text("Elements")
            } footer: {
                Text(
                    "Elements without an own colour keep the standard look. The Live Activity takes over a change with the next update."
                )
            }.listRowBackground(Color.chart)

            if !state.colors.isDefault {
                Section {
                    Button(role: .destructive) {
                        state.colors = .default
                    } label: {
                        Text("Reset All Colours")
                            .frame(maxWidth: .infinity)
                    }
                }.listRowBackground(Color.chart)
            }
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Colours")
        .navigationBarTitleDisplayMode(.automatic)
    }

    private func row(for element: LiveActivityColors.Element) -> some View {
        let isCustom = state.colors[element] != nil
        return HStack {
            ColorPicker(
                selection: Binding(
                    get: { state.colors.color(element) ?? defaultSwatch(for: element) },
                    set: { state.colors[element] = $0.liveActivityHex }
                ),
                supportsOpacity: element == .background
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(element.displayName)
                    Text(isCustom ? String(localized: "Own colour") : element.defaultDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isCustom {
                Button {
                    state.colors[element] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .accessibilityLabel(Text("Standard"))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Colour shown in the picker while the element still has its standard look.
    private func defaultSwatch(for element: LiveActivityColors.Element) -> Color {
        switch element {
        case .chartPoints,
             .glucose: return Color(hue: 120.0 / 360.0, saturation: 0.6, brightness: 0.9)
        case .background: return Color.clear
        case .labels,
             .updated: return .secondary
        default: return .primary
        }
    }

    private func color(_ element: LiveActivityColors.Element, _ fallback: Color) -> Color {
        state.colors.color(element) ?? fallback
    }

    private var preview: some View {
        let inRange = Color(hue: 120.0 / 360.0, saturation: 0.6, brightness: 0.9)
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(LiveActivityAttributes.ContentState.formatGlucose(123, units: state.units, forceSign: false))
                    .font(.largeTitle).bold()
                    .foregroundStyle(color(.glucose, inRange))
                Text("\u{2192}")
                    .font(.title2).bold()
                    .foregroundStyle(color(.trend, color(.glucose, inRange)))
                Text(LiveActivityAttributes.ContentState.formatGlucose(6, units: state.units, forceSign: true))
                    .font(.title3)
                    .foregroundStyle(color(.trend, .primary))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0 ..< 6, id: \.self) { index in
                        Circle()
                            .fill(color(.chartPoints, inRange))
                            .frame(width: 6, height: 6)
                            .offset(y: CGFloat([4, 2, 0, -1, 1, 0][index]))
                    }
                }
            }
            HStack {
                previewValue("1.5 U", caption: "IOB", element: .iob)
                Divider()
                previewValue("20 g", caption: "COB", element: .cob)
                Divider()
                previewValue("43.2 U", caption: "TDD", element: .tdd)
                Divider()
                previewValue(
                    Date().formatted(date: .omitted, time: .shortened),
                    caption: String(localized: "Updated"),
                    element: .updated
                )
            }
            .frame(height: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(state.colors.color(.background) ?? Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.05))
        )
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Lock Screen widget preview"))
    }

    private func previewValue(_ value: String, caption: String, element: LiveActivityColors.Element) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline).bold()
                .foregroundStyle(color(element, .primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(color(.labels, .primary))
        }
        .frame(maxWidth: .infinity)
    }
}
