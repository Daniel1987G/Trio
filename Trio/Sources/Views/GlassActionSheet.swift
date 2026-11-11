import SwiftUI

/// One tappable row of a `glassActionSheet`.
struct GlassSheetAction: Identifiable {
    let id = UUID()
    let label: Text
    let role: ButtonRole?
    let handler: () -> Void

    init(_ title: LocalizedStringKey, role: ButtonRole? = nil, handler: @escaping () -> Void = {}) {
        label = Text(title)
        self.role = role
        self.handler = handler
    }

    /// Titles that must not be looked up: dynamic names, or strings already
    /// resolved via `String(localized:)`. Deliberately labelled `verbatim:` so a
    /// plain literal can never bind here and silently skip localization.
    init(verbatim title: String, role: ButtonRole? = nil, handler: @escaping () -> Void = {}) {
        label = Text(verbatim: title)
        self.role = role
        self.handler = handler
    }
}

extension View {
    /// Bottom action sheet in the classic pre-iOS 26 style with Liquid Glass
    /// chrome: floating rounded panels, glass/material background (opaque when
    /// Reduce Transparency is on) and a detached bold Cancel button.
    /// Replaces `confirmationDialog`, which iOS 26 renders as an anchored
    /// popover with low-contrast capsule buttons.
    func glassActionSheet(
        _ title: LocalizedStringKey? = nil,
        message: Text? = nil,
        isPresented: Binding<Bool>,
        actions: [GlassSheetAction],
        onCancel: (() -> Void)? = nil,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassActionSheetModifier(
            isPresented: isPresented,
            title: title.map { Text($0) },
            message: message,
            actions: actions,
            onCancel: onCancel,
            tint: tint
        ))
    }

    /// Variant for dynamic (pre-localized) titles.
    func glassActionSheet(
        _ title: Text,
        message: Text? = nil,
        isPresented: Binding<Bool>,
        actions: [GlassSheetAction],
        onCancel: (() -> Void)? = nil,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassActionSheetModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            actions: actions,
            onCancel: onCancel,
            tint: tint
        ))
    }
}

private struct GlassActionSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: Text?
    let message: Text?
    let actions: [GlassSheetAction]
    let onCancel: (() -> Void)?
    let tint: Color?

    // Shadow state so the cover is always presented/dismissed without its own
    // slide animation; the sheet animates internally.
    @State private var coverShown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, show in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                if show {
                    // next runloop: presenting inside a swipe-action's row
                    // transaction (e.g. delete confirmations) gets swallowed
                    DispatchQueue.main.async {
                        withTransaction(transaction) { coverShown = true }
                    }
                } else {
                    withTransaction(transaction) { coverShown = false }
                }
            }
            .fullScreenCover(isPresented: $coverShown) {
                GlassActionSheetView(
                    title: title,
                    message: message,
                    actions: actions,
                    onCancel: onCancel,
                    tint: tint,
                    isPresented: $isPresented
                )
                .presentationBackground(.clear)
            }
    }
}

private struct GlassActionSheetView: View {
    let title: Text?
    let message: Text?
    let actions: [GlassSheetAction]
    let onCancel: (() -> Void)?
    /// Fills the title/actions panel (e.g. red for a warning); text turns white for contrast.
    let tint: Color?
    @Binding var isPresented: Bool

    @State private var visible = false
    @State private var dimmed = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let panelShape = RoundedRectangle(cornerRadius: GlassChrome.panelCornerRadius, style: .continuous)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(dimmed ? (reduceTransparency ? 0.4 : 0.25) : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss(then: onCancel) }

            if visible {
                VStack(spacing: 10) {
                    actionsPanel
                    cancelPanel
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            // dim snaps in; only the panel slides
            dimmed = true
            withAnimation(.snappy(duration: 0.28)) { visible = true }
        }
    }

    private var actionsPanel: some View {
        VStack(spacing: 0) {
            if title != nil || message != nil {
                VStack(spacing: 4) {
                    if let title { title.font(.footnote).fontWeight(.semibold) }
                    if let message { message.font(.footnote) }
                }
                .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
            }

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                Button {
                    dismiss(then: action.handler)
                } label: {
                    action.label
                        .font(.title3)
                        .foregroundStyle(
                            tint != nil ? Color.white : action.role == .destructive ? Color.red : Color.accentColor
                        )
                        .frame(maxWidth: .infinity, minHeight: 57)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            if let tint { panelShape.fill(tint) } else { panelBackground }
        }
        .clipShape(panelShape)
    }

    private var cancelPanel: some View {
        Button {
            dismiss(then: onCancel)
        } label: {
            Text("Cancel")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 57)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(panelBackground)
        .clipShape(panelShape)
    }

    @ViewBuilder private var panelBackground: some View {
        if reduceTransparency {
            panelShape.fill(GlassChrome.opaqueFill)
        } else if #available(iOS 26.0, *) {
            panelShape.fill(.clear).glassEffect(.regular, in: panelShape)
        } else {
            panelShape.fill(.regularMaterial)
        }
    }

    /// Slide out, run the chosen action, then tear down the cover.
    /// Handler runs first so bindings that clear `presenting`-style state on
    /// dismissal don't wipe the data the action still needs.
    private func dismiss(then handler: (() -> Void)?) {
        withAnimation(.snappy(duration: 0.22)) {
            visible = false
            dimmed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            handler?()
            isPresented = false
        }
    }
}
