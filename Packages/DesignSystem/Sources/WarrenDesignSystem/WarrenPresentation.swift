import SwiftUI

/// Shared elevation for every floating panel, popover content and modal in
/// Warren. One shadow value keeps command palettes, web panels, endpoint
/// popovers and confirmation dialogs reading as the same surface family.
public struct WarrenPanelSurfaceModifier: ViewModifier {
    public let cornerRadius: CGFloat
    public let showsBorder: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = WarrenRadius.base, showsBorder: Bool = true) {
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
    }

    public func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content
            .background(tokens.popoverSurface)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 35, y: 18)
    }
}

public extension View {
    /// Applies the standard floating-panel surface: popover background,
    /// shared radius, hairline border and the single Warren elevation shadow.
    func warrenPanelSurface(
        cornerRadius: CGFloat = WarrenRadius.base,
        showsBorder: Bool = true
    ) -> some View {
        modifier(WarrenPanelSurfaceModifier(
            cornerRadius: cornerRadius,
            showsBorder: showsBorder
        ))
    }
}

/// Full-window modal scrim shared by every custom dialog. The backdrop uses
/// the same 50% black scrim as the command palette so modal and palette
/// never disagree about how much of the app should recede.
public struct WarrenModalBackdrop<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            content
        }
        .transition(.opacity)
    }
}

/// Labeled input field with the Warren surface language: sunken input
/// background, subtle border, small radius and an accent focus ring.
public struct WarrenInputField: View {
    private let label: String
    private let placeholder: String
    private let monospaced: Bool
    private let focusOnAppear: Bool
    private let onSubmit: (() -> Void)?

    @Binding private var text: String
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        monospaced: Bool = true,
        focusOnAppear: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.monospaced = monospaced
        self.focusOnAppear = focusOnAppear
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text(label)
                .font(WarrenTypography.bodyEmphasis)
                .foregroundStyle(tokens.mutedForeground)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? WarrenTypography.code : WarrenTypography.body)
                .focused($isFocused)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(minHeight: 30)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            isFocused ? tokens.highlight : tokens.border,
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .onSubmit {
                    onSubmit?()
                }
                .accessibilityLabel(label)
        }
        .onAppear {
            if focusOnAppear {
                isFocused = true
            }
        }
    }
}

/// Quiet bordered action used for Cancel and non-emphasized dialog actions.
public struct WarrenSecondaryButtonStyle: ButtonStyle {
    public var isFocused: Bool

    public init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, isFocused: isFocused)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let isFocused: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.dark
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused,
                hovered: hovered
            )
            configuration.label
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    state == .pressed
                        ? tokens.fillSelected
                        : (state == .hovered ? tokens.fillHover : Color.clear)
                )
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            state == .focused ? tokens.focusRing : tokens.border,
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
                .onHover { hovered = $0 }
        }
    }
}

/// Filled destructive action used by deletion confirmations.
public struct WarrenDestructiveButtonStyle: ButtonStyle {
    public var isFocused: Bool

    public init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        DestructiveBody(configuration: configuration, isFocused: isFocused)
    }

    private struct DestructiveBody: View {
        let configuration: Configuration
        let isFocused: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.dark
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused,
                hovered: hovered
            )
            configuration.label
                .font(WarrenTypography.bodyEmphasis)
                .foregroundStyle(.white)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    state == .pressed
                        ? tokens.destructive.opacity(0.82)
                        : tokens.destructive
                )
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            state == .focused ? tokens.focusRing : Color.clear,
                            lineWidth: state == .focused ? 1 : 0
                        )
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
                .onHover { hovered = $0 }
        }
    }
}

/// Reusable text-input dialog with the shared modal surface: scrim, panel,
/// visible label, focus on open, Return to confirm and Escape to cancel.
public struct WarrenTextInputDialog: View {
    public let title: String
    public let message: String
    public let fieldLabel: String
    public let confirmLabel: String
    public let isDestructive: Bool
    public let onCancel: () -> Void
    public let onConfirm: () -> Void

    @Binding public var text: String
    @Environment(\.colorScheme) private var colorScheme

    public init(
        title: String,
        message: String,
        fieldLabel: String,
        text: Binding<String>,
        confirmLabel: String = "Rename",
        isDestructive: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.fieldLabel = fieldLabel
        self._text = text
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenModalBackdrop {
            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                Text(title)
                    .font(WarrenTypography.dialogTitle)
                    .foregroundStyle(tokens.foreground)

                Text(message)
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                WarrenInputField(
                    fieldLabel,
                    text: $text,
                    monospaced: false,
                    focusOnAppear: true,
                    onSubmit: onConfirm
                )

                HStack(spacing: WarrenSpacing.compact) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(WarrenSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    if isDestructive {
                        Button(confirmLabel, action: onConfirm)
                            .buttonStyle(WarrenDestructiveButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button(confirmLabel, action: onConfirm)
                            .buttonStyle(WarrenPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(WarrenSpacing.large)
            .frame(width: 400)
            .warrenPanelSurface(cornerRadius: WarrenRadius.large)
        }
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
