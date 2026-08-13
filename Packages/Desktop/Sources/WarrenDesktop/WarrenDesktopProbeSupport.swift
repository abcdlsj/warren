import SwiftUI

/// Test-only environment switch used by the non-visual semantic UI probe.
///
/// Superset reveals row secondary actions (new session, close tab) on hover.
/// The offscreen harness has no pointer tracking, so the probe forces the
/// hover state through the environment. Production
/// composition roots never set this value; default behavior is unchanged.
private struct WarrenForceHoverKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var warrenForceHover: Bool {
        get { self[WarrenForceHoverKey.self] }
        set { self[WarrenForceHoverKey.self] = newValue }
    }
}
