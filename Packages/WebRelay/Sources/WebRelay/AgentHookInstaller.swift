import Foundation

/// Installs Warren-owned lifecycle hooks without replacing user configuration.
/// Every managed command contains a stable marker, so repeated installation
/// removes only Warren entries and appends exactly one current entry.
enum AgentHookInstaller {
    static let marker = "warren-agent-hook-v1"

    static func install(port: UInt16, token: String) -> [String: String] {
        guard let scriptURL = installScript() else { return [:] }
        let command = "[ -n \"$WARREN_SESSION_ID\" ] && [ -x \(shellQuote(scriptURL.path)) ] && \(shellQuote(scriptURL.path)) || true # \(marker)"
        mergeHooks(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json"),
            events: [
                "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
                "StopFailure", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            ],
            command: command
        )
        mergeHooks(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/hooks.json"),
            events: [
                "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
                "PermissionRequest", "PostToolUse",
            ],
            command: command
        )
        return [
            "WARREN_HOOK_URL": "http://127.0.0.1:\(port)/hook",
            "WARREN_HOOK_TOKEN": token,
        ]
    }

    private static func installScript() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Warren/Hooks", isDirectory: true)
        guard let base else { return nil }
        let url = base.appendingPathComponent("notify.sh")
        let script = managedScript
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            return nil
        }
    }

    static func scriptForTesting() -> String { managedScript }

    private static let managedScript = #"""
        #!/bin/sh
        # warren-agent-hook-v1
        [ -n "$WARREN_SESSION_ID" ] || exit 0
        [ -n "$WARREN_HOOK_URL" ] || exit 0
        if [ -n "$1" ]; then INPUT=$1; else INPUT=$(cat); fi
        EVENT=$(printf '%s' "$INPUT" | sed -nE 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
        [ -n "$EVENT" ] || EVENT=$(printf '%s' "$INPUT" | sed -nE 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
        AGENT_SESSION_ID=$(printf '%s' "$INPUT" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
        [ -n "$AGENT_SESSION_ID" ] || AGENT_SESSION_ID=$(printf '%s' "$INPUT" | sed -nE 's/.*"thread_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
        case "$EVENT" in
          SessionStart|UserPromptSubmit|Start|task_started|PostToolUse) STATE=working ;;
          PermissionRequest|exec_approval_request|apply_patch_approval_request|request_user_input) STATE=waitingForInput ;;
          Stop|agent-turn-complete|task_complete) STATE=ready ;;
          SessionEnd) STATE=exited ;;
          Failed|StopFailure|PostToolUseFailure) STATE=failed ;;
          *) exit 0 ;;
        esac
        curl -fsS --connect-timeout 1 --max-time 2 \
          -G "$WARREN_HOOK_URL" \
          --data-urlencode "session=$WARREN_SESSION_ID" \
          --data-urlencode "state=$STATE" \
          --data-urlencode "agent_session_id=$AGENT_SESSION_ID" \
          --data-urlencode "token=$WARREN_HOOK_TOKEN" \
          >/dev/null 2>&1 || true
        exit 0
        """#

    static func mergeHooksForTesting(at url: URL, events: [String], command: String) {
        mergeHooks(at: url, events: events, command: command)
    }

    private static func mergeHooks(at url: URL, events: [String], command: String) {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            root = decoded
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for key in Set(hooks.keys).union(events) {
            let current = hooks[key] as? [[String: Any]] ?? []
            let cleaned = current.compactMap { definition -> [String: Any]? in
                var definition = definition
                let commands = (definition["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains(marker) == true)
                }
                guard !commands.isEmpty else { return nil }
                definition["hooks"] = commands
                return definition
            }
            hooks[key] = cleaned
        }
        for event in events {
            var definitions = hooks[event] as? [[String: Any]] ?? []
            var definition: [String: Any] = [
                "hooks": [["type": "command", "command": command]],
            ]
            if event == "PermissionRequest" || event == "PostToolUse" || event == "PostToolUseFailure" {
                definition["matcher"] = "*"
            }
            definitions.append(definition)
            hooks[event] = definitions
        }
        root["hooks"] = hooks
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
