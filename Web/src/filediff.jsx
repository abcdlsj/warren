import { useMemo } from "react";
import { parseDiff } from "./git.js";

function DiffLine({ line }) {
  return (
    <div className={`git-diff-line git-diff-line-${line.kind}`}>
      <span className="git-diff-line-num">{line.oldLine}</span>
      <span className="git-diff-line-num">{line.newLine}</span>
      <span className="git-diff-line-mark">{line.kind === "add" ? "+" : line.kind === "del" ? "-" : ""}</span>
      <span className="git-diff-line-text">{line.text}</span>
    </div>
  );
}

export function FileDiffView({ path, staged, commit, loading, diff, content, error, onClose }) {
  const diffLines = useMemo(() => parseDiff(diff), [diff]);
  const changedLines = useMemo(
    () => new Set(diffLines.filter(line => line.kind === "add").map(line => line.newLine)),
    [diffLines],
  );
  const contentLines = useMemo(() => {
    const lines = (content || "").split("\n");
    if (lines.at(-1) === "") lines.pop();
    return lines;
  }, [content]);

  return (
    <section className="file-diff-view" aria-label="File diff">
      <header className="file-diff-header">
        <div className="file-diff-title">
          <code className="file-diff-path">{path}</code>
          {staged && <span className="file-diff-badge">staged</span>}
          {commit && <code className="file-diff-commit">{commit}</code>}
        </div>
        <button type="button" className="chrome-button" aria-label="Close file diff" onClick={onClose}>
          ✕
        </button>
      </header>
      {loading ? (
        <p className="git-empty file-diff-empty">Loading diff…</p>
      ) : error ? (
        <p className="git-error file-diff-empty">{error}</p>
      ) : (
        <div className="file-diff-body">
          <section className="file-diff-pane">
            <h3 className="file-diff-pane-title">File</h3>
            <pre className="file-diff-content">
              {contentLines.map((line, index) => (
                <div key={index} className={`file-diff-content-line${changedLines.has(index + 1) ? " changed" : ""}`}>
                  <span className="file-diff-content-num">{index + 1}</span>
                  <span className="file-diff-content-text">{line}</span>
                </div>
              ))}
            </pre>
          </section>
          <section className="file-diff-pane">
            <h3 className="file-diff-pane-title">Diff</h3>
            <pre className="git-diff-view">
              {diffLines.map((line, index) => (
                <DiffLine key={index} line={line} />
              ))}
            </pre>
          </section>
        </div>
      )}
    </section>
  );
}
