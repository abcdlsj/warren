import { useMemo, useState } from "react";
import { File, PatchDiff, Virtualizer, WorkerPoolContextProvider } from "@pierre/diffs/react";
import PierreDiffWorker from "@pierre/diffs/worker/worker.js?worker&type=module";

const DIFF_THEME = "pierre-dark";

const DIFF_LANGUAGES = [
  "text", "ansi", "js", "jsx", "ts", "tsx", "json", "css", "html", "xml",
  "go", "python", "shell", "markdown", "yaml", "toml", "sql",
  "java", "c", "cpp", "rust", "diff", "ini", "dockerfile", "graphql",
];

function diffOptions(diffStyle) {
  return {
    theme: DIFF_THEME,
    themeType: "dark",
    diffStyle,
    diffIndicators: "classic",
    lineDiffType: "word",
    disableFileHeader: true,
    enableLineSelection: true,
    lineHoverHighlight: "number",
  };
}

const fileOptions = {
  theme: DIFF_THEME,
  themeType: "dark",
  disableFileHeader: true,
};

function DiffSurface({ children }) {
  return (
    <WorkerPoolContextProvider
      poolOptions={{ poolSize: 2, workerFactory: () => new PierreDiffWorker() }}
      highlighterOptions={{ langs: DIFF_LANGUAGES, theme: DIFF_THEME }}
    >
      {children}
    </WorkerPoolContextProvider>
  );
}

export function FileDiffView({ path, staged, commit, loading, diff, content, error, onClose }) {
  const [diffStyle, setDiffStyle] = useState("unified");
  const options = useMemo(() => diffOptions(diffStyle), [diffStyle]);

  return (
    <section className="file-diff-view" aria-label="File diff">
      <header className="file-diff-header">
        <div className="file-diff-title">
          <code className="file-diff-path">{path}</code>
          {staged && <span className="file-diff-badge">staged</span>}
          {commit && <code className="file-diff-commit">{commit}</code>}
        </div>
        <div className="file-diff-actions">
          <div className="file-diff-style-toggle" role="group" aria-label="Diff layout">
            <button
              type="button"
              className={diffStyle === "unified" ? "file-diff-style-button active" : "file-diff-style-button"}
              onClick={() => setDiffStyle("unified")}
            >
              Unified
            </button>
            <button
              type="button"
              className={diffStyle === "split" ? "file-diff-style-button active" : "file-diff-style-button"}
              onClick={() => setDiffStyle("split")}
            >
              Split
            </button>
          </div>
          <button type="button" className="chrome-button" aria-label="Close file diff" onClick={onClose}>
            ✕
          </button>
        </div>
      </header>
      {loading ? (
        <p className="git-empty file-diff-empty">Loading diff…</p>
      ) : error ? (
        <p className="git-error file-diff-empty">{error}</p>
      ) : (
        <DiffSurface>
          <div className="file-diff-body">
            <section className="file-diff-pane">
              <h3 className="file-diff-pane-title">File</h3>
              <Virtualizer className="file-diff-pane-scroll">
                <File file={{ name: path, contents: content }} options={fileOptions} />
              </Virtualizer>
            </section>
            <section className="file-diff-pane">
              <h3 className="file-diff-pane-title">Diff</h3>
              <Virtualizer className="file-diff-pane-scroll">
                <PatchDiff patch={diff} options={options} />
              </Virtualizer>
            </section>
          </div>
        </DiffSurface>
      )}
    </section>
  );
}
