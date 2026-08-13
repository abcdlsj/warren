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

export function renderTerminalTitle(template, session = {}, workspace = {}, host = {}) {
  const directory = session.directory || workspace.path || "";
  const values = {
    session: session.title || "Session",
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

function directoryName(path) {
  return String(path).split("/").filter(Boolean).pop() || "";
}
