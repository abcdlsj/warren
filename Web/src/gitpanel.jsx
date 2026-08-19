import { useMemo, useState } from "react";
import { normalizeGitPanel, relativeTime, statusLabel } from "./git.js";

function ChangeRow({ change }) {
  return (
    <li className="git-change">
      <span className={`git-status git-status-${change.status}`} title={statusLabel(change.status)}>
        {change.status}
      </span>
      <span className="git-change-path">
        {change.path}
        {change.renameFrom && <span className="git-rename-from"> ← {change.renameFrom}</span>}
      </span>
    </li>
  );
}

function ChangeSection({ title, changes }) {
  if (!changes.length) return null;
  return (
    <section className="git-section">
      <h3 className="git-section-title">{title} ({changes.length})</h3>
      <ul className="git-change-list">
        {changes.map((change, index) => (
          <ChangeRow key={`${change.path}-${change.status}-${change.staged}-${index}`} change={change} />
        ))}
      </ul>
    </section>
  );
}

export function GitPanel({
  workspaceName,
  panel,
  loading,
  error,
  action,
  onRefresh,
  onPull,
  onPush,
  onCheckout,
  onClose,
}) {
  const data = useMemo(() => (panel ? normalizeGitPanel(panel) : null), [panel]);
  const [branch, setBranch] = useState("");
  const [newBranch, setNewBranch] = useState("");
  const [createMode, setCreateMode] = useState(false);
  const [expanded, setExpanded] = useState(new Set());
  const busy = Boolean(action) || loading;

  const toggleCommit = hash => {
    setExpanded(previous => {
      const next = new Set(previous);
      if (next.has(hash)) next.delete(hash);
      else next.add(hash);
      return next;
    });
  };

  const submitCheckout = () => {
    if (createMode) {
      const name = newBranch.trim();
      if (name) onCheckout(name, true);
    } else if (branch) {
      onCheckout(branch, false);
    }
  };

  return (
    <aside className="git-panel" aria-label="Git">
      <header className="git-panel-header">
        <strong className="git-panel-title">{workspaceName || "Git"}</strong>
        <button type="button" className="chrome-button" aria-label="Close Git panel" onClick={onClose}>
          ✕
        </button>
      </header>

      {error && <div className="git-error">{error}</div>}

      <div className="git-scroll">
        <section className="git-section">
          <h3 className="git-section-title">Branch</h3>
          <div className="git-branch-line">
            <span className="git-branch-name">{data?.branch || "—"}</span>
            {data?.upstream && <span className="git-upstream">{data.upstream}</span>}
          </div>
          {(data?.ahead > 0 || data?.behind > 0) && (
            <div className="git-ahead-behind">
              {data.ahead > 0 && <span className="git-ahead">↑ {data.ahead} ahead</span>}
              {data.behind > 0 && <span className="git-behind">↓ {data.behind} behind</span>}
            </div>
          )}
          {data?.remote && <div className="git-remote">{data.remote}</div>}
          <div className="git-actions">
            <button type="button" className="chrome-button" onClick={onRefresh} disabled={busy}>Refresh</button>
            <button type="button" className="chrome-button" onClick={onPull} disabled={busy || !data}>
              {action === "git.pull" ? "Pulling…" : "Pull"}
            </button>
            <button type="button" className="chrome-button" onClick={onPush} disabled={busy || !data}>
              {action === "git.push" ? "Pushing…" : "Push"}
            </button>
          </div>
        </section>

        <ChangeSection title="Staged" changes={data?.staged || []} />
        <ChangeSection title="Changes" changes={data?.unstaged || []} />

        <section className="git-section">
          <h3 className="git-section-title">Checkout</h3>
          <div className="git-checkout-row">
            <select
              className="git-select"
              value={branch}
              onChange={event => setBranch(event.target.value)}
              disabled={createMode || !data?.branches.local.length && !data?.branches.remote.length}
            >
              <option value="">Choose a branch…</option>
              {data?.branches.local.map(name => <option key={`l-${name}`} value={name}>{name}</option>)}
              {data?.branches.remote.map(name => <option key={`r-${name}`} value={name}>{name} (remote)</option>)}
            </select>
            {createMode ? (
              <input
                className="git-input"
                value={newBranch}
                onChange={event => setNewBranch(event.target.value)}
                placeholder="New branch name"
                onKeyDown={event => {
                  if (event.key === "Enter") submitCheckout();
                }}
              />
            ) : null}
            <button type="button" className="chrome-button" onClick={submitCheckout} disabled={busy || (!createMode && !branch)}>
              {action === "git.checkout" ? "Switching…" : createMode ? "Create" : "Checkout"}
            </button>
            <button
              type="button"
              className="chrome-button"
              onClick={() => {
                setCreateMode(!createMode);
                setNewBranch("");
              }}
            >
              {createMode ? "Existing" : "New"}
            </button>
          </div>
        </section>

        <section className="git-section">
          <h3 className="git-section-title">History</h3>
          {!data?.commits.length && <p className="git-empty">No commits</p>}
          <ul className="git-commit-list">
            {data?.commits.map(commit => (
              <li key={commit.hash} className="git-commit">
                <button type="button" className="git-commit-summary" onClick={() => toggleCommit(commit.hash)}>
                  <span className="git-commit-subject">{commit.subject}</span>
                  <span className="git-commit-meta">
                    <code>{commit.short}</code> · {commit.author} · {relativeTime(commit.time)}
                  </span>
                </button>
                {expanded.has(commit.hash) && (
                  <ul className="git-change-list">
                    {commit.files.map((file, index) => (
                      <ChangeRow key={`${commit.hash}-${file.path}-${index}`} change={file} />
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        </section>
      </div>
    </aside>
  );
}
