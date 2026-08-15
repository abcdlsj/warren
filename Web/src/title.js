export const defaultTitleTemplate = "{command} — {directoryName}";

export const titlePlaceholders = {
  session: "Session name",
  command: "Current process",
  directory: "Full directory",
  directoryName: "Directory name",
  workspace: "Workspace name",
  branch: "Git branch",
  host: "Host name",
  user: "User name",
  os: "Operating system",
};

const placeholderPattern = new RegExp(`\\{(${Object.keys(titlePlaceholders).join("|")})\\}`, "g");
const separators = "—|·:/-";
const shellProcessNames = new Set([
  "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
  "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
]);
const kindLabels = {
  claude: "Claude Code",
  codex: "Codex",
  custom: "Custom",
};

export function renderTerminalTitle(template, session = {}, workspace = {}, host = {}) {
  const directory = session.directory || workspace.path || "";
  const values = {
    session: session.customTitle || session.title || "Session",
    command: session.process || session.kind || "shell",
    directory,
    directoryName: directoryName(directory),
    workspace: workspace.name || "",
    branch: workspace.branch || "",
    host: host.name || "",
    user: host.user || "",
    os: host.os || "",
  };

  const title = template
    .replace(placeholderPattern, (_, key) => values[key] || "")
    .replace(new RegExp(`\\s+([${separators}])\\s*(?=([${separators}]|$))`, "g"), "")
    .replace(/\s{2,}/g, " ")
    .replace(new RegExp(`^[\\s${separators}]+|[\\s${separators}]+$`, "g"), "");

  return title || values.session;
}

/**
 * Tab title matching Superset's GroupStrip: interactive shells read as their
 * directory, while a real process is shown as "command — directory".
 */
export function terminalTabTitle(session = {}, workspace = {}) {
  const customTitle = String(session.customTitle || "").trim();
  if (customTitle) return customTitle;
  const dirName = directoryName(session.directory || workspace.path || "");
  const process = String(session.process || "").trim();
  const command = process && !shellProcessNames.has(process)
    ? process
    : (session.kind && session.kind !== "shell" ? kindLabels[session.kind] || session.kind : "");
  if (!dirName) return session.title || command || "Shell";
  return command ? `${command} — ${dirName}` : dirName;
}

function directoryName(path) {
  return String(path).split("/").filter(Boolean).pop() || "";
}
