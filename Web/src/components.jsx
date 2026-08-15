import { useEffect, useMemo, useRef, useState } from "react";
import { webAssetURL } from "./runtime.js";

const activityLabels = {
  working: "Working",
  waitingForInput: "Needs input",
  failed: "Failed",
  ready: "Ready",
  exited: "Exited",
  connecting: "Connecting",
};

const activityPriority = {
  failed: 5,
  waitingForInput: 4,
  connecting: 3,
  working: 2,
  ready: 1,
  exited: 0,
};

const terminalIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <path d="m7 9 3 3-3 3m5 0h5" />
  </svg>
);

const folderIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
    <path d="M3 7h7l2 2h9v10H3z" />
    <path d="M3 7V5h7l2 2" />
  </svg>
);

export function ActivityDot({ activity }) {
  const label = activityLabels[activity];
  if (!label) return null;
  const pulse = activity === "ready" || activity === "exited" ? "" : " pulse";
  return <span className={`activity ${activity}${pulse}`} title={label} aria-label={label} />;
}

export function Sidebar({
  catalog,
  activeWorkspace,
  expandedProjects,
  tabsForWorkspace,
  connection,
  onToggleProject,
  onChooseWorkspace,
  onOpenWorkspace,
  onNewSession,
  onOpenSettings,
}) {
  return (
    <aside className="sidebar" aria-label="Projects and workspaces">
      <div className="brand">
        <span className="brand-mark">B</span>
        <span>Warren</span>
        <span className={`connection${connection.online ? " online" : ""}`}>
          <span className="connection-dot" />
          <span>{connection.message}</span>
        </span>
      </div>
      <div className="sidebar-scroll">
        <div className="section-label">PROJECTS</div>
        {catalog.projects.length ? catalog.projects.map(project => {
          const workspaces = catalog.workspacesByProject.get(project.id) || [];
          const open = expandedProjects.has(project.id);
          return (
            <section className={`project${open ? " open" : ""}`} key={project.id}>
              <div className="project-toggle">
                <button
                  type="button"
                  className="project-toggle-main"
                  aria-expanded={open}
                  onClick={() => onToggleProject(project.id)}
                >
                  <span className="branch">{project.name}</span>
                  <span className="project-count">({workspaces.length})</span>
                </button>
                {workspaces[0] && (
                  <button
                    type="button"
                    className="project-add"
                    aria-label={`New session in ${project.name}`}
                    title="New session"
                    onClick={event => {
                      event.stopPropagation();
                      onOpenWorkspace(workspaces[0].id);
                    }}
                  >
                    <PlusIcon />
                  </button>
                )}
                <button
                  type="button"
                  className="project-chevron"
                  aria-label={open ? `Collapse ${project.name}` : `Expand ${project.name}`}
                  onClick={() => onToggleProject(project.id)}
                >
                  <span className="chevron">›</span>
                </button>
              </div>
              <div className="workspace-list">
                {workspaces.map(workspace => (
                  <button
                    type="button"
                    className={`workspace-row${workspace.id === activeWorkspace ? " active" : ""}`}
                    key={workspace.id}
                    onClick={() => onChooseWorkspace(workspace.id)}
                    onDoubleClick={() => onOpenWorkspace(workspace.id)}
                  >
                    <ActivityDot activity={highestActivity(tabsForWorkspace(workspace.id))} />
                    <span className="branch">{workspace.branch || workspace.name || "Workspace"}</span>
                  </button>
                ))}
              </div>
            </section>
          );
        }) : <div className="workspace-row">No projects</div>}
      </div>
      <footer className="sidebar-footer">
        <button
          type="button"
          className="footer-new-session"
          disabled={!activeWorkspace}
          onClick={onNewSession}
        >
          <PlusIcon />
          <span>New Session</span>
        </button>
        <button type="button" className="chrome-button" aria-label="Settings" onClick={onOpenSettings}>
          <SettingsIcon />
        </button>
      </footer>
    </aside>
  );
}

export function TopBar({
  tabs,
  activeSession,
  onAttachSession,
  onNewSession,
  onOpenMenu,
  onOpenSearch,
}) {
  const tabRefs = useRef(new Map());

  useEffect(() => {
    if (!activeSession) return;
    const node = tabRefs.current.get(activeSession);
    node?.scrollIntoView({ inline: "nearest", block: "nearest", behavior: "smooth" });
  }, [activeSession, tabs]);

  return (
    <header className="topbar">
      <button type="button" className="menu-button" aria-label="Open navigation" onClick={onOpenMenu}>☰</button>
      <div className="tabs" role="tablist">
        {tabs.map(session => {
          const active = session.id === activeSession;
          return (
            <button
              type="button"
              role="tab"
              aria-selected={active}
              className={`tab${active ? " active" : ""}`}
              key={session.id}
              onClick={() => onAttachSession(session.id)}
              ref={node => {
                if (node) tabRefs.current.set(session.id, node);
                else tabRefs.current.delete(session.id);
              }}
            >
              <ActivityDot activity={session.activity} />
              <span className="tab-title">{session.title}</span>
            </button>
          );
        })}
      </div>
      <button type="button" className="new-session" aria-label="New shell" onClick={onNewSession}>+</button>
      <div className="chrome-spacer" />
      <button type="button" className="chrome-button" aria-label="Search projects" onClick={onOpenSearch}>
        <SearchIcon />
      </button>
    </header>
  );
}

export function PresetBar({ presets, onCreateSession }) {
  return (
    <nav className="presetbar" aria-label="Session presets">
      {presets.map(preset => (
        <button type="button" className="preset" key={preset.kind} onClick={() => onCreateSession(preset.kind)}>
          {preset.kind === "codex" ? (
            <picture>
              <source media="(prefers-color-scheme:dark)" srcSet={webAssetURL("preset-codex-white.svg")} />
              <img src={webAssetURL("preset-codex.svg")} alt="" />
            </picture>
          ) : <img src={webAssetURL(`preset-${preset.kind}.svg`)} alt="" />}
          {preset.label}
        </button>
      ))}
    </nav>
  );
}

export function EmptyTerminal({
  activeWorkspace,
  activeSession,
  attachedSession,
  tabCount,
  projectCount,
  override,
  onNewSession,
}) {
  let content;
  let hidden = false;

  if (override) {
    content = override.loading ? <Loading message={override.message} /> : <span>{override.message}</span>;
  } else if (activeSession && attachedSession === activeSession) {
    hidden = true;
    content = null;
  } else if (activeSession) {
    content = <Loading message="Connecting…" />;
  } else if (activeWorkspace && tabCount) {
    content = <span>Select a session</span>;
  } else if (activeWorkspace) {
    content = (
      <div className="empty-state">
        {terminalIcon}
        <div className="empty-title">Start a session</div>
        <button type="button" className="empty-action" onClick={onNewSession}>New Session</button>
      </div>
    );
  } else {
    content = (
      <div className="empty-state">
        {folderIcon}
        <div className="empty-title">{projectCount ? "Select a workspace" : "No projects on this host"}</div>
      </div>
    );
  }

  return <div className="terminal-empty" hidden={hidden}>{content}</div>;
}

export function MobileKeys({ onInput }) {
  const keys = [
    ["escape", "Esc", "\u001b"],
    ["tab", "Tab", "\t"],
    ["ctrlC", "Ctrl-C", "\u0003"],
    ["ctrlD", "Ctrl-D", "\u0004"],
    ["up", "↑", "\u001b[A"],
    ["down", "↓", "\u001b[B"],
    ["left", "←", "\u001b[D"],
    ["right", "→", "\u001b[C"],
  ];
  return (
    <nav className="mobile-keys" aria-label="Terminal keys">
      {keys.map(([key, label, sequence]) => (
        <button type="button" className="mobile-key" key={key} onClick={() => onInput(sequence)}>{label}</button>
      ))}
    </nav>
  );
}

export function SettingsPage({
  open,
  fontFamily,
  fontSize,
  titleTemplate,
  titlePreview,
  placeholders,
  onClose,
  onFontFamilyChange,
  onFontSizeChange,
  onTitleTemplateChange,
  onAppendPlaceholder,
  onRestore,
}) {
  const [activeSection, setActiveSection] = useState("font");
  const [searchQuery, setSearchQuery] = useState("");

  const sections = useMemo(() => [
    {
      id: "font",
      label: "Terminal font",
      description: "Applied to every web terminal.",
      keywords: ["font", "family", "size", "typography"],
    },
    {
      id: "title",
      label: "Terminal title",
      description: "Build a title from live Session metadata.",
      keywords: ["title", "template", "placeholder", "preview"],
    },
  ], []);

  const needle = searchQuery.trim().toLowerCase();
  const visibleSections = useMemo(() => {
    if (!needle) return sections;
    return sections.filter(section =>
      [section.label, section.description, ...section.keywords]
        .some(value => String(value).toLowerCase().includes(needle)),
    );
  }, [needle, sections]);

  useEffect(() => {
    if (!open) setSearchQuery("");
  }, [open]);

  useEffect(() => {
    if (needle && visibleSections.length && !visibleSections.some(section => section.id === activeSection)) {
      setActiveSection(visibleSections[0].id);
    }
  }, [needle, activeSection, visibleSections]);

  return (
    <section className={`settings-page settings${open ? " open" : ""}`} aria-label="Settings">
      <nav className="settings-nav" aria-label="Settings sections">
        <div className="settings-nav-top">
          <button type="button" className="settings-back" aria-label="Back to Warren" onClick={onClose}>
            <BackIcon />
            <span>Back</span>
          </button>
          <h1 className="settings-title">Settings</h1>
        </div>
        <div className="settings-search">
          <SearchIcon />
          <input
            value={searchQuery}
            onChange={event => setSearchQuery(event.target.value)}
            placeholder="Search settings…"
            autoComplete="off"
            spellCheck="false"
          />
          {searchQuery && (
            <button
              type="button"
              className="settings-search-clear"
              aria-label="Clear settings search"
              onClick={() => setSearchQuery("")}
            >
              ×
            </button>
          )}
        </div>
        <div className="settings-nav-scroll">
          <div className="settings-nav-label">TERMINAL</div>
          {visibleSections.map(section => (
            <button
              type="button"
              className={`settings-nav-item${activeSection === section.id ? " active" : ""}`}
              aria-current={activeSection === section.id ? "true" : undefined}
              key={section.id}
              onClick={() => setActiveSection(section.id)}
            >
              {section.id === "font" ? terminalIcon : <TitleIcon />}
              <span>{section.label}</span>
            </button>
          ))}
          {!visibleSections.length && <div className="settings-nav-empty">No settings found</div>}
        </div>
      </nav>
      <div className="settings-detail">
        <div className="settings-content">
          {visibleSections.length ? (
            activeSection === "font" ? (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Terminal font</h2>
                  <p>Applied to every web terminal.</p>
                </header>
                <div className="settings-fields">
                  <label>
                    Font family
                    <input value={fontFamily} onChange={event => onFontFamilyChange(event.target.value)} autoComplete="off" spellCheck="false" />
                  </label>
                  <label>
                    Size
                    <input type="number" min="8" max="32" step="1" value={fontSize} onChange={event => onFontSizeChange(event.target.value)} />
                  </label>
                </div>
                <div className="font-preview" style={{ fontFamily, fontSize: `${fontSize}px` }}>Aa&nbsp;&nbsp;The quick brown fox&nbsp;&nbsp;0123456789</div>
              </section>
            ) : (
              <section className="settings-section">
                <header className="settings-page-heading">
                  <h2>Terminal title</h2>
                  <p>Build a title from live Session metadata.</p>
                </header>
                <label>
                  Title template
                  <input value={titleTemplate} onChange={event => onTitleTemplateChange(event.target.value)} autoComplete="off" spellCheck="false" />
                </label>
                <div className="settings-preview">Preview: {titlePreview}</div>
                <div className="placeholder-list">
                  {placeholders.map(([key, description]) => (
                    <button type="button" className="placeholder" key={key} title={description} onClick={() => onAppendPlaceholder(`{${key}}`)}>{`{${key}}`}</button>
                  ))}
                </div>
              </section>
            )
          ) : (
            <div className="settings-empty">No settings match “{searchQuery}”.</div>
          )}
          <div className="settings-footer">
            <button type="button" className="settings-reset" onClick={onRestore}>Restore Terminal Defaults</button>
          </div>
        </div>
      </div>
    </section>
  );
}

export function SearchPanel({
  open,
  query,
  catalog,
  onQueryChange,
  onClose,
  onChooseWorkspace,
  onChooseProject,
}) {
  const inputRef = useRef(null);
  const itemRefs = useRef(new Map());
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    if (open) {
      inputRef.current?.focus();
      setActiveIndex(0);
    }
  }, [open]);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  const needle = query.trim().toLowerCase();
  const matches = value => !needle || String(value || "").toLowerCase().includes(needle);

  const groups = [];
  let nextIndex = 0;
  for (const project of catalog.projects) {
    const workspaces = catalog.workspacesByProject.get(project.id) || [];
    const projectMatches = matches(project.name) || matches(project.path);
    const visibleWorkspaces = workspaces.filter(workspace =>
      projectMatches || matches(workspace.name) || matches(workspace.branch),
    );
    if (!projectMatches && !visibleWorkspaces.length) continue;
    const rows = [{ kind: "project", project, workspace: null, index: nextIndex++ }];
    for (const workspace of visibleWorkspaces) {
      rows.push({ kind: "workspace", project, workspace, index: nextIndex++ });
    }
    groups.push({ project, rows });
  }
  const flatRows = groups.flatMap(group => group.rows);
  const rowCount = flatRows.length;
  const activeRow = flatRows[activeIndex] || null;

  useEffect(() => {
    const node = itemRefs.current.get(activeIndex);
    node?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, query]);

  const chooseRow = row => {
    if (!row) return;
    if (row.kind === "project") onChooseProject(row.project.id);
    else onChooseWorkspace(row.workspace.id);
  };

  const handleKeyDown = event => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (rowCount) setActiveIndex(index => Math.min(index + 1, rowCount - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveIndex(index => Math.max(index - 1, 0));
    } else if (event.key === "Home") {
      event.preventDefault();
      setActiveIndex(0);
    } else if (event.key === "End") {
      event.preventDefault();
      setActiveIndex(rowCount - 1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      chooseRow(activeRow);
    }
  };

  return (
    <div
      className={`search-overlay${open ? " open" : ""}`}
      onMouseDown={event => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section className="search-panel" role="dialog" aria-modal="true" aria-label="Project search">
        <div className="search-input-wrap">
          <SearchIcon />
          <input
            ref={inputRef}
            className="search-input"
            value={query}
            onChange={event => onQueryChange(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command or search…"
            autoComplete="off"
            spellCheck="false"
          />
          <kbd className="search-kbd">esc</kbd>
        </div>
        <div className="search-results">
          {groups.map(group => (
            <div className="search-group" key={group.project.id}>
              <div className="search-group-heading">{group.project.name}</div>
              {group.rows.map(row => {
                const active = row.index === activeIndex;
                const shared = {
                  ref: node => {
                    if (node) itemRefs.current.set(row.index, node);
                    else itemRefs.current.delete(row.index);
                  },
                  onMouseEnter: () => setActiveIndex(row.index),
                };
                return row.kind === "project" ? (
                  <button
                    type="button"
                    key={row.project.id}
                    className={`search-item search-project-item${active ? " active" : ""}`}
                    {...shared}
                    onClick={() => onChooseProject(row.project.id)}
                  >
                    {folderIcon}
                    <span className="search-copy">
                      <span className="search-name">{row.project.name}</span>
                      <span className="search-path">{row.project.path || ""}</span>
                    </span>
                  </button>
                ) : (
                  <button
                    type="button"
                    key={row.workspace.id}
                    className={`search-item search-workspace-item${active ? " active" : ""}`}
                    {...shared}
                    onClick={() => onChooseWorkspace(row.workspace.id)}
                  >
                    <BranchIcon />
                    <span className="search-name">{row.workspace.branch || row.workspace.name || "Workspace"}</span>
                    <span className="search-kind">Workspace</span>
                  </button>
                );
              })}
            </div>
          ))}
          {!rowCount && <div className="search-empty">No results found.</div>}
        </div>
      </section>
    </div>
  );
}

export function Loading({ message }) {
  return <span className="terminal-loading"><span className="spinner" />{message}</span>;
}

function highestActivity(sessions) {
  return sessions.reduce((highest, session) => {
    const activity = session.activity;
    return (activityPriority[activity] || 0) > (activityPriority[highest] || 0) ? activity : highest;
  }, null);
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <path d="M19 12H5m6-7-7 7 7 7" />
    </svg>
  );
}

function BranchIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <circle cx="6" cy="6" r="2.5" />
      <circle cx="6" cy="18" r="2.5" />
      <circle cx="18" cy="6" r="2.5" />
      <path d="M6 8.5v7M8.5 6h7" />
    </svg>
  );
}

function TitleIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <path d="M4 7V4h16v3M9 20h6M12 4v16" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21H9.6v-.1A1.7 1.7 0 0 0 8.5 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3V9.6h.1A1.7 1.7 0 0 0 4.6 8.5a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.1A1.7 1.7 0 0 0 15.5 4.6a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.16.38.38.72.68 1 .3.28.69.42 1.1.4h.1v4h-.1A1.7 1.7 0 0 0 19.4 15Z" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      <circle cx="11" cy="11" r="6" />
      <path d="m16 16 4 4" />
    </svg>
  );
}
