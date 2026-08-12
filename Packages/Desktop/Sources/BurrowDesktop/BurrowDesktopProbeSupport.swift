import SwiftUI

/// Test-only environment switch used by the ClickProbe executable.
///
/// Superset reveals row secondary actions (new session, close tab) on hover.
/// Synthetic NSEvents cannot reliably drive SwiftUI `.onHover` tracking, so
/// the probe forces the hover state through the environment. Production
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
