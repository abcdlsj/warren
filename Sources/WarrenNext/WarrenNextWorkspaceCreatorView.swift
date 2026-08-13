import SwiftUI
import WarrenApplication
import WarrenDomain
import WarrenDesignSystem

struct WarrenNextWorkspaceCreatorView: View {
    let project: Project
    let onCreate: (WorkspaceCreationRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requestID = UUID()
    @State private var displayName = ""
    @State private var branch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(WarrenTypography.dialogTitle)
            Text("Create a Git worktree for \(project.name).")
                .font(WarrenTypography.body)
                .foregroundStyle(.secondary)

            TextField("Workspace name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            TextField("Branch", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branch) { _, value in
                    if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        displayName = value
                    }
                }

            Text("Worktree files are stored under ~/.warren.")
                .font(WarrenTypography.badge)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(WorkspaceCreationRequest(
                        requestID: requestID,
                        displayName: displayName,
                        branch: branch,
                        path: ""
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
