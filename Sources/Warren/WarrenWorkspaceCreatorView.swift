import SwiftUI
import WarrenDomain
import WarrenDesignSystem

struct WarrenWorkspaceCreatorView: View {
    let project: Project
    let onCreate: (WorkspaceCreationRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var requestID = UUID()
    @State private var displayName = ""
    @State private var branch = ""

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            Text("New workspace")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)
            Text("Create a Git worktree for \(project.name).")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)

            WarrenInputField(
                "Workspace name",
                text: $displayName,
                placeholder: "feature/my-change",
                monospaced: false,
                focusOnAppear: true
            )

            WarrenInputField(
                "Branch",
                text: $branch,
                placeholder: "main",
                monospaced: false
            )
            .onChange(of: branch) { _, value in
                if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayName = value
                }
            }

            Text("Worktree files are stored under ~/.warren/worktrees.")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(WorkspaceCreationRequest(
                        requestID: requestID,
                        displayName: displayName,
                        branch: branch,
                        path: ""
                    ))
                    dismiss()
                }
                .buttonStyle(WarrenPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(
                    branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 480)
        .background(tokens.popoverSurface)
        .onExitCommand {
            dismiss()
        }
    }
}
