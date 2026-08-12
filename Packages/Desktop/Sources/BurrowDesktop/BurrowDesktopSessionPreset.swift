import BurrowDomain

/// Presentation metadata for a built-in session launch request.
///
/// This is the single catalog used by both the pinned command bar and the full
/// session creator. User-defined presets can later conform to the same value
/// shape without changing the Desktop action channel.
public struct BurrowDesktopSessionPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let createButtonTitle: String
    public let request: TerminalSessionLaunchRequest
    public let isPinned: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        symbolName: String,
        createButtonTitle: String,
        request: TerminalSessionLaunchRequest,
        isPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.createButtonTitle = createButtonTitle
        self.request = request
        self.isPinned = isPinned
    }

    public static let builtIns: [Self] = [
        Self(
            id: "shell",
            title: "Interactive Shell",
            subtitle: "Plain shell in the selected workspace",
            symbolName: "terminal",
            createButtonTitle: "Open Shell",
            request: .shell,
            isPinned: true
        ),
        Self(
            id: "claude",
            title: "Claude Code",
            subtitle: "Launch the claude CLI in this project",
            symbolName: "sparkles",
            createButtonTitle: "Start Claude Code",
            request: .claude,
            isPinned: true
        ),
        Self(
            id: "codex",
            title: "Codex",
            subtitle: "Launch the codex CLI in this project",
            symbolName: "curlybraces",
            createButtonTitle: "Start Codex",
            request: .codex,
            isPinned: true
        ),
        Self(
            id: "custom",
            title: "Custom Command",
            subtitle: "Run any command line, agent or development server",
            symbolName: "hammer",
            createButtonTitle: "Start Custom",
            request: TerminalSessionLaunchRequest(kind: .custom),
            isPinned: false
        ),
    ]

    public static let pinned = builtIns.filter(\.isPinned)
}

extension TerminalSessionKind {
    /// Desktop-only icon metadata. Durable Host records keep only the stable
    /// kind and never depend on an SF Symbol name.
    var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .claude: "sparkles"
        case .codex: "curlybraces"
        case .custom: "hammer"
        }
    }
}
