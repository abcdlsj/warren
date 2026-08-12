import SwiftUI

public enum BurrowSemanticAction: String, Codable, Hashable, Sendable {
    case press
}

@MainActor
public final class BurrowSemanticRecorder {
    private var nodes: [BurrowSemanticNode] = []
    private var actions: [String: () -> Void] = [:]

    public init() {}

    public func snapshot() -> BurrowSemanticSnapshot {
        BurrowSemanticSnapshot(
            capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            nodes: nodes
        )
    }

    public func perform(_ action: BurrowSemanticAction, on id: String) throws {
        guard action == .press, let handler = actions[id] else {
            throw BurrowSemanticRecorderError.actionUnavailable(id: id, action: action)
        }
        handler()
    }

    func replace(_ values: [BurrowSemanticNode]) {
        nodes = values
    }

    func registerAction(id: String, action: @escaping () -> Void) {
        actions[id] = action
    }

    func removeAction(id: String) {
        actions[id] = nil
    }
}

public enum BurrowSemanticRecorderError: Error, Equatable {
    case actionUnavailable(id: String, action: BurrowSemanticAction)
}

private struct BurrowSemanticRecorderKey: EnvironmentKey {
    static let defaultValue: BurrowSemanticRecorder? = nil
}

public extension EnvironmentValues {
    var burrowSemanticRecorder: BurrowSemanticRecorder? {
        get { self[BurrowSemanticRecorderKey.self] }
        set { self[BurrowSemanticRecorderKey.self] = newValue }
    }
}

private struct BurrowSemanticPreferenceKey: PreferenceKey {
    static let defaultValue: [BurrowSemanticNode] = []

    static func reduce(
        value: inout [BurrowSemanticNode],
        nextValue: () -> [BurrowSemanticNode]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct BurrowSemanticElementModifier: ViewModifier {
    @Environment(\.burrowSemanticRecorder) private var recorder

    let id: String
    let role: BurrowSemanticRole
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
                    let frame = proxy.frame(in: .named(BurrowSemanticCoordinateSpace.name))
                    Color.clear.preference(
                        key: BurrowSemanticPreferenceKey.self,
                        value: [
                            BurrowSemanticNode(
                                id: id,
                                role: role,
                                label: label,
                                value: value,
                                isEnabled: isEnabled,
                                isSelected: isSelected,
                                isFocused: isFocused,
                                frame: BurrowSemanticRect(
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

private enum BurrowSemanticCoordinateSpace {
    static let name = "BurrowSemanticRoot"
}

public extension View {
    func burrowSemanticElement(
        id: String,
        role: BurrowSemanticRole,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(
            BurrowSemanticElementModifier(
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

    func burrowSemanticObservationRoot(
        recorder: BurrowSemanticRecorder?
    ) -> some View {
        coordinateSpace(name: BurrowSemanticCoordinateSpace.name)
            .onPreferenceChange(BurrowSemanticPreferenceKey.self) { values in
                recorder?.replace(values)
            }
    }
}
