import AppKit

/// AppKit split view that keeps the sidebar and terminal area side by side.
final class RootSplitViewController: NSSplitViewController {

    // MARK: - Child controllers

    private(set) var sidebarController: NSViewController
    private(set) var contentController: NSViewController

    // MARK: - Init

    init(
        sidebarController: NSViewController,
        contentController: NSViewController
    ) {
        self.sidebarController = sidebarController
        self.contentController = contentController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // The sidebar needs enough width for project/worktree nesting without squeezing the terminal too hard.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 320
        sidebarItem.maximumThickness = 520
        sidebarItem.preferredThicknessFraction = 0.3
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .paneSplitter
    }

    // MARK: - Sidebar Toggle

    var isSidebarCollapsed: Bool {
        !splitViewItems.isEmpty && splitViewItems[0].isCollapsed
    }

    func toggleSidebar() {
        guard !splitViewItems.isEmpty else { return }
        let collapsed = splitViewItems[0].isCollapsed
        // Animate manually because the controller is AppKit-driven rather than SwiftUI-driven.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            splitViewItems[0].animator().isCollapsed = !collapsed
        }
    }
}
