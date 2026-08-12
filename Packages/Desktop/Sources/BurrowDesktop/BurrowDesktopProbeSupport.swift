import SwiftUI

/// Test-only environment switch used by the non-visual semantic UI probe.
///
/// Superset reveals row secondary actions (new session, close tab) on hover.
/// The offscreen harness has no pointer tracking, so the probe forces the
/// hover state through the environment. Production
/// composition roots never set this value; default behavior is unchanged.
private struct BurrowForceHoverKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var burrowForceHover: Bool {
        get { self[BurrowForceHoverKey.self] }
        set { self[BurrowForceHoverKey.self] = newValue }
    }
}
