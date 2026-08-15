import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { webAssetURL } from "./runtime.js";
import { terminalSearchSummary } from "./terminal.js";
import { terminalTabTitle } from "./title.js";
import { keyboardInset } from "./viewport.js";

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

const pinIcon = (
  <svg viewBox="0 0 24 24" fill="currentColor" stroke="none" aria-hidden="true">
    <path d="M15 3v6l2 2v2h-4v7l-1 1-1-1v-7H7v-2l2-2V3h6z" />
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
  onProjectContextMenu,
  onWorkspaceContextMenu,
  onMoveProject,
  onMoveWorkspace,
  onBeginProjectDrag,
  onEndProjectDrag,
}) {
  const [dragState, setDragState] = useState(null);
  const [dragOverID, setDragOverID] = useState(null);

  const beginDrag = (kind, id, projectID, event) => {
    if (!(event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      return;
    }
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", id);
    setDragOverID(null);
    setDragState({ kind, id, projectID });
    if (kind === "project") onBeginProjectDrag(expandedProjects);
  };

  const endDrag = () => {
    if (dragState?.kind === "project") onEndProjectDrag();
    setDragState(null);
    setDragOverID(null);
  };

  const projectDragOver = (projectID, event) => {
    if (dragState?.kind !== "project") return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (dragOverID !== projectID) setDragOverID(projectID);
  };

  const workspaceDragOver = (workspace, event) => {
    if (dragState?.kind !== "workspace" || dragState.projectID !== workspace.project) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (dragOverID !== workspace.id) setDragOverID(workspace.id);
  };

  const dropProject = (beforeProjectID, event) => {
    if (dragState?.kind !== "project") return;
    event.preventDefault();
    onMoveProject(dragState.id, beforeProjectID);
    endDrag();
  };

  const dropWorkspace = (workspace, event) => {
    if (dragState?.kind !== "workspace" || dragState.projectID !== workspace.project) return;
    event.preventDefault();
    onMoveWorkspace(dragState.id, workspace.id);
    endDrag();
  };

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
              <div
                className={`project-toggle${dragOverID === project.id ? " drag-over" : ""}`}
                onContextMenu={event => onProjectContextMenu(event, project)}
                draggable
                onDragStart={event => beginDrag("project", project.id, null, event)}
                onDragEnd={endDrag}
                onDragOver={event => projectDragOver(project.id, event)}
                onDrop={event => dropProject(project.id, event)}
              >
                <button
                  type="button"
                  className="project-toggle-main"
                  aria-expanded={open}
                  onClick={() => onToggleProject(project.id)}
                >
                  <span className="branch">{project.name}</span>
                  {project.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
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
                    className={`workspace-row${workspace.id === activeWorkspace ? " active" : ""}${dragOverID === workspace.id ? " drag-over" : ""}`}
                    key={workspace.id}
                    onClick={() => onChooseWorkspace(workspace.id)}
                    onDoubleClick={() => onOpenWorkspace(workspace.id)}
                    onContextMenu={event => onWorkspaceContextMenu(event, workspace)}
                    draggable
                    onDragStart={event => beginDrag("workspace", workspace.id, workspace.project, event)}
                    onDragEnd={endDrag}
                    onDragOver={event => workspaceDragOver(workspace, event)}
                    onDrop={event => dropWorkspace(workspace, event)}
                  >
                    <ActivityDot activity={highestActivity(tabsForWorkspace(workspace.id))} />
                    {workspace.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                    <span className="branch">{workspace.branch || workspace.name || "Workspace"}</span>
                  </button>
                ))}
                {dragState?.kind === "workspace" && dragState.projectID === project.id && (
                  <div
                    className={`sidebar-drop-end${dragOverID === "__workspace_end" ? " drag-over" : ""}`}
                    onDragOver={event => {
                      event.preventDefault();
                      event.dataTransfer.dropEffect = "move";
                      if (dragOverID !== "__workspace_end") setDragOverID("__workspace_end");
                    }}
                    onDrop={event => {
                      if (dragState?.kind !== "workspace") return;
                      event.preventDefault();
                      onMoveWorkspace(dragState.id, null);
                      endDrag();
                    }}
                  />
                )}
              </div>
            </section>
          );
        }) : <div className="workspace-row">No projects</div>}
        {dragState?.kind === "project" && (
          <div
            className={`sidebar-drop-end${dragOverID === "__project_end" ? " drag-over" : ""}`}
            onDragOver={event => {
              event.preventDefault();
              event.dataTransfer.dropEffect = "move";
              if (dragOverID !== "__project_end") setDragOverID("__project_end");
            }}
            onDrop={event => {
              if (dragState?.kind !== "project") return;
              event.preventDefault();
              onMoveProject(dragState.id, null);
              endDrag();
            }}
          />
        )}
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
  workspace,
  onAttachSession,
  onNewSession,
  onOpenMenu,
  onOpenSearch,
  onTabContextMenu,
}) {
  const tabRefs = useRef(new Map());
  const tabsRef = useRef(null);
  const [hasOverflow, setHasOverflow] = useState(false);
  const [canScrollLeft, setCanScrollLeft] = useState(false);
  const [canScrollRight, setCanScrollRight] = useState(false);

  const updateOverflow = useCallback(() => {
    const el = tabsRef.current;
    if (!el) return;
    const maxScrollLeft = el.scrollWidth - el.clientWidth;
    setHasOverflow(maxScrollLeft > 1);
    setCanScrollLeft(el.scrollLeft > 1);
    setCanScrollRight(el.scrollLeft < maxScrollLeft - 1);
  }, []);

  useEffect(() => {
    const el = tabsRef.current;
    if (!el) return;
    const observer = new ResizeObserver(updateOverflow);
    observer.observe(el);
    el.addEventListener("scroll", updateOverflow, { passive: true });
    window.addEventListener("resize", updateOverflow);
    updateOverflow();
    return () => {
      observer.disconnect();
      el.removeEventListener("scroll", updateOverflow);
      window.removeEventListener("resize", updateOverflow);
    };
  }, [updateOverflow, tabs]);

  useEffect(() => {
    if (!activeSession) return;
    const node = tabRefs.current.get(activeSession);
    node?.scrollIntoView({ inline: "nearest", block: "nearest", behavior: "smooth" });
  }, [activeSession, tabs]);

  const scrollTabs = useCallback(direction => {
    const el = tabsRef.current;
    if (!el) return;
    const distance = Math.max(160, el.clientWidth * 0.8);
    el.scrollBy({ left: direction === "left" ? -distance : distance, behavior: "smooth" });
  }, []);

  return (
    <header className="topbar">
      <button type="button" className="menu-button" aria-label="Open navigation" onClick={onOpenMenu}>☰</button>
      <div className="tabs-wrap">
        {hasOverflow && (
          <button
            type="button"
            className="tabs-chevron tabs-chevron-left"
            aria-label="Earlier tabs"
            disabled={!canScrollLeft}
            onClick={() => scrollTabs("left")}
          >
            ‹
          </button>
        )}
        <div
          ref={tabsRef}
          className={`tabs${canScrollLeft ? " fade-left" : ""}${canScrollRight ? " fade-right" : ""}`}
          role="tablist"
        >
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
                onContextMenu={event => onTabContextMenu(event, session)}
                ref={node => {
                  if (node) tabRefs.current.set(session.id, node);
                  else tabRefs.current.delete(session.id);
                }}
              >
                <ActivityDot activity={session.activity} />
                {session.pinned && <span className="pin-icon" title="Pinned">{pinIcon}</span>}
                <span className="tab-title">{terminalTabTitle(session, workspace)}</span>
              </button>
            );
          })}
        </div>
        {hasOverflow && (
          <button
            type="button"
            className="tabs-chevron tabs-chevron-right"
            aria-label="More tabs"
            disabled={!canScrollRight}
            onClick={() => scrollTabs("right")}
          >
            ›
          </button>
        )}
      </div>
      <button type="button" className="new-session" aria-label="New shell" onClick={onNewSession}>+</button>
      <div className="chrome-spacer" />
      <button type="button" className="chrome-button" aria-label="Search projects" onClick={onOpenSearch}>
        <SearchIcon />
      </button>
    </header>
  );
}

export function ContextMenu({ menu, onClose }) {
  const menuRef = useRef(null);

  useEffect(() => {
    if (!menu) return undefined;
    const handlePointerDown = event => {
      if (!menuRef.current?.contains(event.target)) onClose();
    };
    const handleKeyDown = event => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("blur", onClose);
    };
  }, [menu, onClose]);

  if (!menu) return null;
  return (
    <div
      ref={menuRef}
      className="context-menu"
      role="menu"
      style={{ left: menu.x, top: menu.y }}
    >
      {menu.items.map((item, index) => (
        <button
          type="button"
          role="menuitem"
          key={index}
          onClick={() => {
            onClose();
            item.action();
          }}
        >
          {item.label}
        </button>
      ))}
    </div>
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

export function TerminalSearch({
  open,
  query,
  resultIndex,
  resultCount,
  focusNonce,
  onQueryChange,
  onNext,
  onPrevious,
  onClose,
}) {
  const inputRef = useRef(null);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open, focusNonce]);

  const handleKeyDown = event => {
    if (event.key === "Enter") {
      event.preventDefault();
      if (event.shiftKey) onPrevious();
      else onNext();
    } else if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  };

  if (!open) return null;

  const summary = terminalSearchSummary(resultIndex, resultCount, Boolean(query));
  const hasMatches = Boolean(query) && resultCount > 0;
  return (
    <div className="terminal-search" role="search" aria-label="Search terminal">
      <SearchIcon />
      <input
        ref={inputRef}
        value={query}
        onChange={event => onQueryChange(event.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="Find…"
        aria-label="Find in terminal"
        autoComplete="off"
        spellCheck="false"
      />
      <span className="terminal-search-count">{summary}</span>
      <button type="button" aria-label="Previous match" title="Previous match (⇧↵)" disabled={!hasMatches} onClick={onPrevious}>
        <ChevronUpIcon />
      </button>
      <button type="button" aria-label="Next match" title="Next match (↵)" disabled={!hasMatches} onClick={onNext}>
        <ChevronDownIcon />
      </button>
      <button type="button" aria-label="Close search" title="Close search (esc)" onClick={onClose}>
        <CloseIcon />
      </button>
    </div>
  );
}

export function MobileKeys({ onInput }) {
  const barRef = useRef(null);
  // Two balanced rows keep every row full: navigation/common keys on top,
  // Ctrl chords below. Buttons stretch to share the row evenly.
  const keyRows = [
    [
      ["escape", "Esc", "\u001b"],
      ["tab", "Tab", "\t"],
      ["home", "Home", "\u001b[H"],
      ["end", "End", "\u001b[F"],
      ["up", "↑", "\u001b[A"],
      ["down", "↓", "\u001b[B"],
      ["left", "←", "\u001b[D"],
      ["right", "→", "\u001b[C"],
    ],
    [
      ["ctrlC", "Ctrl-C", "\u0003"],
      ["ctrlD", "Ctrl-D", "\u0004"],
      ["ctrlA", "Ctrl-A", "\u0001"],
      ["ctrlE", "Ctrl-E", "\u0005"],
      ["ctrlU", "Ctrl-U", "\u0015"],
      ["ctrlK", "Ctrl-K", "\u000b"],
      ["ctrlL", "Ctrl-L", "\u000c"],
    ],
  ];

  useEffect(() => {
    const bar = barRef.current;
    const viewport = window.visualViewport;
    const main = bar?.parentElement;
    if (!bar || !main || !viewport) return undefined;

    // Apply the keyboard inset only at discrete open/close points instead of
    // on every visualViewport event. During the keyboard animation those
    // events fire per frame; following them continuously resizes the shell
    // and makes the terminal canvas flicker.
    const OPEN_THRESHOLD_PX = 24;
    let keyboardOpen = false;
    let appliedInset = 0;
    const apply = inset => {
      main.style.paddingBottom = inset > 0 ? `${inset}px` : "";
      bar.classList.toggle("keyboard-open", inset > 0);
    };
    const update = () => {
      // Cross-platform keyboard inset: Android resizes the layout viewport
      // (covered ~= 0, bottom stays 0), iOS keeps the layout height and pans
      // the visual viewport (covered == keyboard height). Shrink the main
      // grid with bottom padding so the shell and the shortcut bar both sit
      // above the keyboard; clear it again once the keyboard collapses.
      const inset = keyboardInset(window.innerHeight, viewport.height, viewport.offsetTop);
      if (keyboardOpen) {
        if (inset === 0) {
          keyboardOpen = false;
          appliedInset = 0;
          apply(0);
        } else if (inset > appliedInset) {
          // Follow a keyboard that grows taller (IME/layout switch), but
          // never shrink mid-animation so the shell does not jitter.
          appliedInset = inset;
          apply(inset);
        }
      } else if (inset > OPEN_THRESHOLD_PX) {
        keyboardOpen = true;
        appliedInset = inset;
        apply(inset);
      }
    };
    update();
    viewport.addEventListener("resize", update);
    viewport.addEventListener("scroll", update);
    window.addEventListener("resize", update);
    return () => {
      viewport.removeEventListener("resize", update);
      viewport.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, []);

  return (
    <nav ref={barRef} className="mobile-keys" aria-label="Terminal keys">
      {keyRows.map((row, rowIndex) => (
        <div className="mobile-key-row" key={rowIndex}>
          {row.map(([key, label, sequence]) => (
            <button type="button" className="mobile-key" key={key} onClick={() => onInput(sequence)}>{label}</button>
          ))}
        </div>
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
      label: "Font",
      description: "Applied to every web terminal.",
      keywords: ["font", "family", "size", "typography"],
    },
    {
      id: "title",
      label: "Title",
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

function ChevronUpIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
      <path d="m6 15 6-6 6 6" />
    </svg>
  );
}

function ChevronDownIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" />
    </svg>
  );
}
