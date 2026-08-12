import SwiftUI
import BurrowDesktop
import BurrowDomain

/// A small, opinionated launcher for the kinds of sessions Burrow is built
/// around: an interactive shell, Claude Code, Codex, or an arbitrary command.
/// The selected template is translated into a Host `createSession` call; Burrow
/// does not embed or wrap the agent binary.
struct BurrowNextSessionCreatorView: View {
    let workspaceName: String
    let onCreate: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: TerminalSessionKind = .shell
    @State private var customCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Session")
                    .font(.system(size: 17, weight: .semibold))
                Text(workspaceName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(spacing: 6) {
                ForEach(BurrowDesktopSessionPreset.builtIns) { template in
                    templateRow(template)
                }

                if selectedKind == .custom {
                    TextField("Command, e.g. npm run dev", text: $customCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            .padding(.vertical, 10)

            Divider()

            HStack {
                Text("Agents run as real CLIs in the terminal.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(createTitle) {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedKind == .custom && customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(.background)
    }

    private var createTitle: String {
        selectedPreset?.createButtonTitle ?? "Start Session"
    }

    private func templateRow(_ preset: BurrowDesktopSessionPreset) -> some View {
        let isSelected = selectedKind == preset.request.kind
        return Button {
            selectedKind = preset.request.kind
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(preset.subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private func create() {
        let request: TerminalSessionLaunchRequest
        if selectedKind == .custom {
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            request = TerminalSessionLaunchRequest(
                kind: .custom,
                command: trimmed,
                title: trimmed.split(separator: " ").first.map(String.init)
            )
        } else {
            guard let preset = selectedPreset else { return }
            request = preset.request
        }
        onCreate(request)
        dismiss()
    }

    private var selectedPreset: BurrowDesktopSessionPreset? {
        BurrowDesktopSessionPreset.builtIns.first { $0.request.kind == selectedKind }
    }
}
