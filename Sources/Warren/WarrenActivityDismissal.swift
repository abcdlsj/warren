import WarrenDomain

/// Client-local rule for hiding an agent activity dot after the user drags it
/// out of the window.
///
/// The dismissal covers only the activity state that was visible when the dot
/// was dismissed. A later activity change makes the dot visible again, so a
/// new Codex/Claude run in the same session still lights up normally.
enum WarrenActivityDismissal {
    struct Presentation: Equatable, Sendable {
        let activity: AgentActivityState?
        let clearsDismissal: Bool
    }

    static func presentedActivity(
        candidate: AgentActivityState?,
        dismissed: AgentActivityState?
    ) -> Presentation {
        guard let dismissed else { return Presentation(activity: candidate, clearsDismissal: false) }
        if dismissed == candidate { return Presentation(activity: nil, clearsDismissal: false) }
        return Presentation(activity: candidate, clearsDismissal: true)
    }
}
