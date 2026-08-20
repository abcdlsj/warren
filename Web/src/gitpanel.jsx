import { useEffect, useMemo, useState } from "react";
import { normalizeGitPanel, relativeTime, statusLabel, statusSymbol, diffSummary } from "./git.js";

function DiffCounts({ added, deleted }) {
  if (!added && !deleted) return null;
  return (
    <span className="git-diff-counts">
      {added > 0 && <span className="git-diff-added">+{added}</span>}
      {deleted > 0 && <span className="git-diff-deleted">-{deleted}</span>}
    </span>
  );
}

function changeKey(change, commit = "") {
  return commit ? `${commit}:${change.path}` : `${change.staged ? "s" : "u"}:${change.path}`;
}

function ChangeRow({ change, commit = "", selected, onOpenFile }) {
  return (
    <li>
      <button
        type="button"
        className={`git-change${selected ? " selected" : ""}`}
        aria-pressed={selected}
        onClick={() => onOpenFile(change, commit)}
      >
        <span className={`git-status git-status-${change.status}`} title={statusLabel(change.status)}>
          {statusSymbol(change.status)}
        </span>
        <span className="git-change-path">
          {change.path}
          {change.renameFrom && <span className="git-rename-from"> ← {change.renameFrom}</span>}
        </span>
        <DiffCounts added={change.added} deleted={change.deleted} />
      </button>
    </li>
  );
}

const operationLabels = {
  rebase: "Rebase",
  merge: "Merge",
  "cherry-pick": "Cherry-pick",
  revert: "Revert",
};

const prStateLabels = {
  open: "Open",
  merged: "Merged",
  closed: "Closed",
};

function PullRequestView({ pr }) {
  return (
    <div className="git-pr">
      <div className="git-pr-header">
        <span className="git-pr-number">#{pr.number}</span>
        <span className={`git-pr-state git-pr-state-${pr.state}`}>{prStateLabels[pr.state] || pr.state}</span>
        {pr.draft && <span className="git-pr-draft">Draft</span>}
      </div>
      <p className="git-pr-title">{pr.title}</p>
      <p className="git-pr-meta">
        {pr.author} · {pr.base} ← {pr.head}
      </p>
      {pr.body && <p className="git-pr-body">{pr.body}</p>}
      <a className="chrome-button git-pr-link" href={pr.url} target="_blank" rel="noreferrer">
        Open pull request ↗
      </a>
    </div>
  );
}

function ChangeSection({ title, changes, selectedKey, onOpenFile }) {
  if (!changes.length) return null;
  const summary = diffSummary(changes);
  return (
    <section className="git-section">
      <h3 className="git-section-title">
        {title} ({changes.length})
        <DiffCounts added={summary.added} deleted={summary.deleted} />
      </h3>
      <ul className="git-change-list">
        {changes.map((change, index) => (
          <ChangeRow
            key={`${change.path}-${change.status}-${change.staged}-${index}`}
            change={change}
            selected={selectedKey === changeKey(change)}
            onOpenFile={onOpenFile}
          />
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
  onOpenFile,
  onCommit,
  onCreatePR,
  onClose,
}) {
  const data = useMemo(() => (panel ? normalizeGitPanel(panel) : null), [panel]);
  const [branch, setBranch] = useState("");
  const [branchTouched, setBranchTouched] = useState(false);
  const [newBranch, setNewBranch] = useState("");
  const [createMode, setCreateMode] = useState(false);
  const [expanded, setExpanded] = useState(new Set());
  const [selectedKey, setSelectedKey] = useState(null);
  const [commitOpen, setCommitOpen] = useState(false);
  const [commitMessage, setCommitMessage] = useState("");
  const [prOpen, setPrOpen] = useState(false);
  const [prTitle, setPrTitle] = useState("");
  const [prBody, setPrBody] = useState("");
  const busy = Boolean(action) || loading;
  const historyCommits = data?.mainBranch && !data.operation ? (data.unmergedCommits || []) : (data?.commits || []);
  const mainShort = data?.mainBranch?.includes("/") ? data.mainBranch.slice(data.mainBranch.indexOf("/") + 1) : data?.mainBranch || "";
  const canCreatePR = Boolean(
    data && data.remote && data.branch && data.mainBranch &&
    data.branch !== mainShort && !data.merged && !data.operation &&
    !data.pullRequest && !data.pullRequestError && data.unmergedCommits.length > 0,
  );

  const openCommit = () => {
    setCommitMessage("");
    setCommitOpen(true);
  };

  const submitCommit = () => {
    const message = commitMessage.trim();
    if (!message) return;
    setCommitOpen(false);
    onCommit(message);
  };

  const openCreatePR = () => {
    const commits = data?.unmergedCommits || [];
    setPrTitle(commits[0]?.subject || data?.branch || "");
    setPrBody(commits.map(commit => `- ${commit.subject} (${commit.short})`).join("\n"));
    setPrOpen(true);
  };

  const submitCreatePR = () => {
    const title = prTitle.trim();
    if (!title) return;
    setPrOpen(false);
    onCreatePR(title, prBody.trim());
  };

  useEffect(() => {
    if (!branchTouched && data?.branch && data.branches.local.includes(data.branch)) {
      setBranch(data.branch);
    }
  }, [branchTouched, data]);

  const openFile = (change, commit = "") => {
    const key = changeKey(change, commit);
    setSelectedKey(previous => (previous === key ? null : key));
    onOpenFile(change, commit);
  };

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
        <section className="git-section git-fixed-section">
          <h3 className="git-section-title">Branch</h3>
          {data?.operation && (
            <div className="git-operation-warning">
              {operationLabels[data.operation] || data.operation} in progress — resolve it before pushing or pulling
            </div>
          )}
          <div className="git-branch-line">
            <span className="git-branch-name">{data?.branch || "—"}</span>
            {data?.upstream && <span className="git-upstream">{data.upstream}</span>}
          </div>
          {data?.mainBranch && !data.operation &&
            (data.merged ? (
              <div className="git-merged-badge">Merged into {data.mainBranch}</div>
            ) : (
              <div className="git-unmerged-count">
                {data.unmergedCommits.length
                  ? `${data.unmergedCommits.length} commit${data.unmergedCommits.length === 1 ? "" : "s"} not in ${data.mainBranch}`
                  : `Up to date with ${data.mainBranch}`}
              </div>
            ))}
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
            <button
              type="button"
              className="chrome-button"
              onClick={() => {
                if (data && (data.staged.length || data.unstaged.length)) openCommit();
                else onPush();
              }}
              disabled={busy || !data}
            >
              {action === "git.push" ? "Pushing…" : "Push"}
            </button>
          </div>
          {commitOpen && (
            <div className="git-commit-box">
              <p className="git-commit-hint">Commit changes before pushing</p>
              <input
                className="git-input"
                value={commitMessage}
                onChange={event => setCommitMessage(event.target.value)}
                placeholder="Commit message"
                autoFocus
                onKeyDown={event => {
                  if (event.key === "Enter") submitCommit();
                  if (event.key === "Escape") setCommitOpen(false);
                }}
              />
              <div className="git-commit-actions">
                <button type="button" className="chrome-button" onClick={submitCommit} disabled={!commitMessage.trim() || busy}>
                  {action === "git.commit" ? "Committing…" : "Commit & Push"}
                </button>
                <button type="button" className="chrome-button" onClick={() => setCommitOpen(false)}>
                  Cancel
                </button>
              </div>
            </div>
          )}
        </section>

        {data?.remote && (
          <section className="git-section git-fixed-section">
            <h3 className="git-section-title">Pull Request</h3>
            {data.pullRequest ? (
              <PullRequestView pr={data.pullRequest} />
            ) : data.pullRequestError ? (
              <p className="git-pr-error">{data.pullRequestError}</p>
            ) : canCreatePR ? (
              prOpen ? (
                <div className="git-pr-form">
                  <input
                    className="git-input"
                    value={prTitle}
                    onChange={event => setPrTitle(event.target.value)}
                    placeholder="Pull request title"
                    autoFocus
                    onKeyDown={event => {
                      if (event.key === "Enter") submitCreatePR();
                      if (event.key === "Escape") setPrOpen(false);
                    }}
                  />
                  <textarea
                    className="git-textarea"
                    value={prBody}
                    onChange={event => setPrBody(event.target.value)}
                    placeholder="Description"
                    rows={4}
                  />
                  <p className="git-commit-hint">
                    Merge into {data.mainBranch} from {data.branch}
                  </p>
                  <div className="git-commit-actions">
                    <button
                      type="button"
                      className="chrome-button"
                      onClick={submitCreatePR}
                      disabled={!prTitle.trim() || busy}
                    >
                      {action === "git.pr.create" ? "Creating…" : "Create pull request"}
                    </button>
                    <button type="button" className="chrome-button" onClick={() => setPrOpen(false)}>
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <button type="button" className="chrome-button" onClick={openCreatePR} disabled={busy}>
                  Create pull request
                </button>
              )
            ) : (
              <p className="git-empty">No pull request</p>
            )}
          </section>
        )}

        <div className="git-pane git-pane-changes">
          <ChangeSection title="Staged" changes={data?.staged || []} selectedKey={selectedKey} onOpenFile={openFile} />
          <ChangeSection title="Changes" changes={data?.unstaged || []} selectedKey={selectedKey} onOpenFile={openFile} />
        </div>

        <div className="git-pane git-pane-history">
          <section className="git-section">
            <h3 className="git-section-title">
              History
              {data?.mainBranch && !data.merged && !data.operation && <span className="git-history-scope">not in {data.mainBranch}</span>}
            </h3>
            {!historyCommits.length && (
              <p className="git-empty">
                {data?.mainBranch && !data.operation ? `All commits are in ${data.mainBranch}` : "No commits"}
              </p>
            )}
            <ul className="git-commit-list">
              {historyCommits.map(commit => (
                <li key={commit.hash} className="git-commit">
                  <button type="button" className="git-commit-summary" aria-expanded={expanded.has(commit.hash)} onClick={() => toggleCommit(commit.hash)}>
                    <span className="git-commit-subject">{commit.subject}</span>
                    <span className="git-commit-meta">
                      <code>{commit.short}</code> · {commit.author} · {relativeTime(commit.time)}
                      <DiffCounts {...diffSummary(commit.files)} />
                    </span>
                  </button>
                  {expanded.has(commit.hash) && (
                    <ul className="git-change-list">
                      {commit.files.map((file, index) => (
                        <ChangeRow
                          key={`${commit.hash}-${file.path}-${index}`}
                          change={file}
                          commit={commit.hash}
                          selected={selectedKey === changeKey(file, commit.hash)}
                          onOpenFile={openFile}
                        />
                      ))}
                    </ul>
                  )}
                </li>
              ))}
            </ul>
          </section>
        </div>

        <section className="git-section git-fixed-section">
          <h3 className="git-section-title">Checkout</h3>
          <div className="git-checkout-row">
            <select
              className="git-select"
              aria-label="Branch"
              value={branch}
              onChange={event => {
                setBranch(event.target.value);
                setBranchTouched(true);
              }}
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
            <button type="button" className="chrome-button" onClick={submitCheckout} disabled={busy || (createMode ? !newBranch.trim() : !branch)}>
              {action === "git.checkout" ? "Switching…" : createMode ? "Create" : "Checkout"}
            </button>
            <button
              type="button"
              className="chrome-button"
              disabled={busy}
              onClick={() => {
                setCreateMode(!createMode);
                setNewBranch("");
              }}
            >
              {createMode ? "Existing" : "New"}
            </button>
          </div>
        </section>

      </div>
    </aside>
  );
}
