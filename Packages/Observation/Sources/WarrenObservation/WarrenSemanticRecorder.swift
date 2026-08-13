import SwiftUI

public enum WarrenSemanticAction: String, Codable, Hashable, Sendable {
    case press
}

@MainActor
public final class WarrenSemanticRecorder {
    private var nodes: [WarrenSemanticNode] = []
    private var actions: [String: () -> Void] = [:]

    public init() {}

    public func snapshot() -> WarrenSemanticSnapshot {
        WarrenSemanticSnapshot(
            capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            nodes: nodes
        )
    }

    public func perform(_ action: WarrenSemanticAction, on id: String) throws {
        guard action == .press, let handler = actions[id] else {
            throw WarrenSemanticRecorderError.actionUnavailable(id: id, action: action)
        }
        handler()
    }

    func replace(_ values: [WarrenSemanticNode]) {
        nodes = values
    }

    func registerAction(id: String, action: @escaping () -> Void) {
        actions[id] = action
    }

    func removeAction(id: String) {
        actions[id] = nil
    }
}

public enum WarrenSemanticRecorderError: Error, Equatable {
    case actionUnavailable(id: String, action: WarrenSemanticAction)
}

private struct WarrenSemanticRecorderKey: EnvironmentKey {
    static let defaultValue: WarrenSemanticRecorder? = nil
}

public extension EnvironmentValues {
    var warrenSemanticRecorder: WarrenSemanticRecorder? {
        get { self[WarrenSemanticRecorderKey.self] }
        set { self[WarrenSemanticRecorderKey.self] = newValue }
    }
}

private struct WarrenSemanticPreferenceKey: PreferenceKey {
    static let defaultValue: [WarrenSemanticNode] = []

    static func reduce(
        value: inout [WarrenSemanticNode],
        nextValue: () -> [WarrenSemanticNode]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct WarrenSemanticElementModifier: ViewModifier {
    @Environment(\.warrenSemanticRecorder) private var recorder

    let id: String
    let role: WarrenSemanticRole
    let label: String
    let value: String?
    let isEnabled: Bool
    let isSelected: Bool
    let isFocused: Bool
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .overlay {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(WarrenSemanticCoordinateSpace.name))
                    Color.clear.preference(
                        key: WarrenSemanticPreferenceKey.self,
                        value: [
                            WarrenSemanticNode(
                                id: id,
                                role: role,
                                label: label,
                                value: value,
                                isEnabled: isEnabled,
                                isSelected: isSelected,
                                isFocused: isFocused,
                                frame: WarrenSemanticRect(
                                    x: frame.origin.x,
                                    y: frame.origin.y,
                                    width: frame.size.width,
                                    height: frame.size.height
                                )
                            ),
                        ]
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear {
                if let action {
                    recorder?.registerAction(id: id, action: action)
                }
            }
            .onDisappear {
                recorder?.removeAction(id: id)
            }
    }
}

private enum WarrenSemanticCoordinateSpace {
    static let name = "WarrenSemanticRoot"
}

public extension View {
    func warrenSemanticElement(
        id: String,
        role: WarrenSemanticRole,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(
            WarrenSemanticElementModifier(
                id: id,
                role: role,
                label: label,
                value: value,
                isEnabled: isEnabled,
                isSelected: isSelected,
                isFocused: isFocused,
                action: action
            )
        )
    }

    func warrenSemanticObservationRoot(
        recorder: WarrenSemanticRecorder?
    ) -> some View {
        coordinateSpace(name: WarrenSemanticCoordinateSpace.name)
            .onPreferenceChange(WarrenSemanticPreferenceKey.self) { values in
                recorder?.replace(values)
            }
    }
}
