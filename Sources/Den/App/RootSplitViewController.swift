import AppKit

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

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultHigh

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
    }

    // MARK: - Sidebar Toggle

    var isSidebarCollapsed: Bool {
        !splitViewItems.isEmpty && splitViewItems[0].isCollapsed
    }

    func toggleSidebar() {
        guard !splitViewItems.isEmpty else { return }
        let collapsed = splitViewItems[0].isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            splitViewItems[0].animator().isCollapsed = !collapsed
        }
    }
}
