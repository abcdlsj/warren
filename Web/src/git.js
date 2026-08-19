export function normalizeGitPanel(payload) {
  const changes = payload?.changes || [];
  return {
    branch: payload?.branch || "",
    upstream: payload?.upstream || "",
    ahead: payload?.ahead || 0,
    behind: payload?.behind || 0,
    remote: payload?.remote || "",
    staged: changes.filter(change => change.staged),
    unstaged: changes.filter(change => !change.staged),
    commits: (payload?.commits || []).map(commit => ({
      ...commit,
      files: commit.files || [],
    })),
    branches: {
      local: (payload?.branches || []).filter(branch => !branch.remote).map(branch => branch.name),
      remote: (payload?.branches || []).filter(branch => branch.remote).map(branch => branch.name),
    },
  };
}

export const statusLabels = {
  M: "Modified",
  A: "Added",
  D: "Deleted",
  R: "Renamed",
  C: "Copied",
  U: "Unmerged",
  T: "Type change",
  "?": "Untracked",
};

export function statusLabel(status) {
  return statusLabels[status] || status;
}

export function relativeTime(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 60) return "just now";
  const units = [
    [60, "minute"],
    [3600, "hour"],
    [86400, "day"],
    [604800, "week"],
    [2592000, "month"],
    [31536000, "year"],
  ];
  for (let i = units.length - 1; i >= 0; i--) {
    const [size, name] = units[i];
    if (seconds >= size) {
      const count = Math.floor(seconds / size);
      return `${count} ${name}${count === 1 ? "" : "s"} ago`;
    }
  }
}

export function diffSummary(changes) {
  return (changes || []).reduce(
    (total, change) => ({
      added: total.added + (change.added || 0),
      deleted: total.deleted + (change.deleted || 0),
    }),
    { added: 0, deleted: 0 },
  );
}
