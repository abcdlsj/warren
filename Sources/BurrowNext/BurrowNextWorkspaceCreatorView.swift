import SwiftUI
import BurrowApplication
import BurrowDomain
import BurrowDesignSystem

struct BurrowNextWorkspaceCreatorView: View {
    let project: Project
    let onCreate: (WorkspaceCreationRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requestID = UUID()
    @State private var branch = ""
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(BurrowTypography.dialogTitle)
            Text("Create a Git worktree for \(project.name).")
                .font(BurrowTypography.body)
                .foregroundStyle(.secondary)

            TextField("Branch", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branch) { _, value in
                    guard !value.isEmpty else { return }
                    let base = URL(fileURLWithPath: project.rootPath)
                        .deletingLastPathComponent()
                    path = base.appendingPathComponent(
                        "\(project.name)-\(value.replacingOccurrences(of: "/", with: "-"))"
                    ).path
                }
            TextField("Worktree path", text: $path)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(WorkspaceCreationRequest(
                        requestID: requestID,
                        branch: branch,
                        path: path
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
