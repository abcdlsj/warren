import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

import { buildCatalog, moveInCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import { WarrenConnection } from "./connection.js";
import {
  captureNavigationPosition,
  resolveRestoredWorkspace,
  restoreNavigationPosition,
} from "./navigation.js";
import { runtime, serviceWorkerURL, webSocketURL } from "./runtime.js";
import { defaultTitleTemplate, renderTerminalTitle, titlePlaceholders } from "./title.js";
import {
  attachTerminalMessage,
  fitTerminalToHost,
  terminalSize,
  waitForTerminalFont,
} from "./terminal.js";
import { mergeAgentEvents } from "./agent.js";
import { AgentView } from "./agent.jsx";
import { InputQueue, MobileInputDeduper } from "./input.js";
import { OutputBatcher } from "./output.js";
import { decodeOutputFrame, isBinaryEnvelope } from "./wire.js";
import {
  EmptyTerminal,
  ContextMenu,
  MobileKeys,
  PresetBar,
  SearchPanel,
  SettingsPage,
  Sidebar,
  TerminalSearch,
  TopBar,
} from "./components.jsx";
import { enableTerminalTouchScroll } from "./touch.js";

const storageKeys = {
  activeWorkspace: "warren.activeWorkspace",
  activeSession: "warren.activeSession",
  expandedProjects: "warren.expandedProjects",
  fontFamily: "warren.terminalFontFamily",
  fontSize: "warren.terminalFontSize",
  titleTemplate: "warren.terminalTitleTemplate",
  presetCommands: "warren.presetCommands",
};

const defaultFontFamily = 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace';
const defaultFontSize = matchMedia("(max-width: 760px)").matches ? 12 : 13;
const terminalTheme = {
  background: "#151110",
  foreground: "#eae8e6",
  cursor: "#e07850",
  cursorAccent: "#151110",
  selectionBackground: "rgba(224, 120, 80, 0.25)",
  black: "#151110",
  red: "#dc6b6b",
  green: "#7ec699",
  yellow: "#e5c07b",
  blue: "#61afef",
  magenta: "#c678dd",
  cyan: "#56b6c2",
  white: "#eae8e6",
  brightBlack: "#5c5856",
  brightRed: "#e88888",
  brightGreen: "#98d1a8",
  brightYellow: "#ecd08f",
  brightBlue: "#7ec0f5",
  brightMagenta: "#d494e6",
  brightCyan: "#73c7d3",
  brightWhite: "#ffffff",
};
const pendingInputLimit = 64 * 1024;
const terminalSearchDecorations = {
  matchBackground: "#3a3837",
  matchOverviewRuler: "#f59e0b",
  activeMatchBackground: "#e07850",
  activeMatchColorOverviewRuler: "#e07850",
};
const isCoarsePointer = () => (
  typeof window.matchMedia === "function"
    ? window.matchMedia("(pointer: coarse)").matches
    : false
);
const previewSession = {
  title: "Claude",
  process: "claude",
  directory: "/Users/me/Workspace/warren",
  kind: "claude",
};
const previewWorkspace = {
  name: "warren",
  branch: "main",
  path: "/Users/me/Workspace/warren",
};
const defaultPresetCommands = {
  shell: "",
  claude: "claude",
  codex: "codex --dangerously-bypass-hook-trust",
};
const sessionPresets = [
  { kind: "shell", label: "Shell", title: "Shell" },
  { kind: "claude", label: "Claude", title: "Claude Code" },
  { kind: "codex", label: "Codex", title: "Codex" },
];

export default function App() {
  const [catalog, setCatalog] = useState(() => buildCatalog());
  const [activeWorkspace, setActiveWorkspace] = useState(() => localStorage.getItem(storageKeys.activeWorkspace));
  const [activeSession, setActiveSession] = useState(() => localStorage.getItem(storageKeys.activeSession));
  const [attachedSession, setAttachedSession] = useState(null);
  const [expandedProjects, setExpandedProjects] = useState(() => loadSet(storageKeys.expandedProjects));
  const [fontFamily, setFontFamily] = useState(() => localStorage.getItem(storageKeys.fontFamily) || defaultFontFamily);
  const [fontSize, setFontSize] = useState(() => Number(localStorage.getItem(storageKeys.fontSize)) || defaultFontSize);
  const [titleTemplate, setTitleTemplate] = useState(() => localStorage.getItem(storageKeys.titleTemplate) || defaultTitleTemplate);
  const [presetCommands, setPresetCommands] = useState(() => loadPresetCommands());
  const [connectionStatus, setConnectionStatus] = useState({ message: "Connecting…", online: false });
  const [emptyOverride, setEmptyOverride] = useState(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [terminalSearchOpen, setTerminalSearchOpen] = useState(false);
  const [terminalSearchQuery, setTerminalSearchQuery] = useState("");
  const [terminalSearchIndex, setTerminalSearchIndex] = useState(-1);
  const [terminalSearchCount, setTerminalSearchCount] = useState(0);
  const [terminalSearchFocusNonce, setTerminalSearchFocusNonce] = useState(0);
  const [contextMenu, setContextMenu] = useState(null);
  const [agentStateBySession, setAgentStateBySession] = useState({});
  const [agentViewOverride, setAgentViewOverride] = useState(null);

  const connectionRef = useRef(null);
  const terminalHostRef = useRef(null);
  const terminalRef = useRef(null);
  const fitAddonRef = useRef(null);
  const searchAddonRef = useRef(null);
  const webglAddonRef = useRef(null);
  const fitTimerRef = useRef(null);
  const resizeTimerRef = useRef(null);
  const pendingTerminalSizeRef = useRef(null);
  const sentTerminalSizeRef = useRef(null);
  const focusedSessionRef = useRef(null);
  const batcherRef = useRef(null);
  const recoveryAnchorRef = useRef(null);
  const pendingStartAnchorRef = useRef(null);
  const reanchorRequiredRef = useRef(false);
  const snapshotPendingRef = useRef(false);
  const messageHandlerRef = useRef(() => {});
  const connectionStateHandlerRef = useRef(() => {});
  const maintenanceTimeoutRef = useRef(null);
  const appStateRef = useRef({});
   const pendingRequestsRef = useRef(new Map());
   const inputQueueRef = useRef(null);
   const navigationBeforeSettingsRef = useRef(null);
  const autoFocusOnAttachRef = useRef(true);
  const projectDragRef = useRef(null);
  if (inputQueueRef.current === null) {
    inputQueueRef.current = new InputQueue({
      limit: pendingInputLimit,
      send: data => Boolean(connectionRef.current?.sendBinary(data)),
      onSendFailure: () => connectionRef.current?.reconnectNow(),
    });
  }

  const clearMaintenanceTimeout = useCallback(() => {
    if (maintenanceTimeoutRef.current !== null) {
      clearTimeout(maintenanceTimeoutRef.current);
      maintenanceTimeoutRef.current = null;
    }
  }, []);

  const scheduleMaintenanceTimeout = useCallback(() => {
    clearMaintenanceTimeout();
    maintenanceTimeoutRef.current = setTimeout(() => {
      maintenanceTimeoutRef.current = null;
      setConnectionStatus({ message: "Reconnecting…", online: false });
    }, 10_000);
  }, [clearMaintenanceTimeout]);

  const selectedWorkspaceID = useMemo(() => {
    if (activeWorkspace && catalog.workspaces.some(workspace => workspace.id === activeWorkspace)) {
      return activeWorkspace;
    }
    return catalog.workspaces[0]?.id || null;
  }, [activeWorkspace, catalog.workspaces]);
  const selectedWorkspace = useMemo(
    () => catalog.workspaces.find(workspace => workspace.id === selectedWorkspaceID) || null,
    [catalog.workspaces, selectedWorkspaceID],
  );
  const tabs = useMemo(
    () => selectedWorkspaceID ? workspaceTabs(catalog, selectedWorkspaceID) : [],
    [catalog, selectedWorkspaceID],
  );
  const selectedSession = activeSession ? catalog.sessions.get(activeSession) || null : null;
  const paneTitle = selectedSession
    ? renderTerminalTitle(titleTemplate, selectedSession, selectedWorkspace, catalog.host)
    : "";
  const titlePreview = renderTerminalTitle(
    titleTemplate,
    selectedSession || previewSession,
    selectedWorkspace || previewWorkspace,
    catalog.host,
  );

  appStateRef.current = {
    catalog,
    activeWorkspace: selectedWorkspaceID,
    activeSession,
    attachedSession,
  };

  const request = useCallback((method, params = {}, onResult = null) => {
    const id = connectionRef.current?.request(method, params);
    if (!id) return false;
    if (onResult) pendingRequestsRef.current.set(id, onResult);
    return true;
  }, []);

  const markAttachReady = useCallback((sessionID, flush = true) => {
    const state = appStateRef.current;
    if (state.activeSession !== sessionID) return;
    // The attach response is ordered before subsequent WebSocket frames, so
    // it is safe to accept input even if a legacy relay omits `attached`.
    state.attachedSession = sessionID;
    setAttachedSession(sessionID);
    if (flush) inputQueueRef.current.flush(sessionID);
    // Touch devices must not pop the software keyboard as a side effect of
    // attaching a session; the user focuses the terminal by tapping it.
    if (autoFocusOnAttachRef.current && !isCoarsePointer()) terminalRef.current?.focus();
  }, []);

  const sendInput = useCallback(data => {
    const state = appStateRef.current;
    if (!data || !state.activeSession) return;
    if (state.attachedSession !== state.activeSession) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      return;
    }
    if (!connectionRef.current?.sendBinary(data)) {
      inputQueueRef.current.enqueue(state.activeSession, data);
      connectionRef.current?.reconnectNow();
    }
  }, []);

  const sendAgentInput = useCallback(text => {
    // The agent process is a TUI: the only input channel is the PTY. Normal
    // newlines become terminal returns so Enter submits exactly like typing
    // in the terminal.
    sendInput(text.replace(/\n/g, "\r") + "\r");
  }, [sendInput]);

  const fitTerminal = useCallback(() => {
    if (fitTimerRef.current !== null) {
      clearTimeout(fitTimerRef.current);
      fitTimerRef.current = null;
    }
    const node = terminalHostRef.current;
    fitTerminalToHost(fitAddonRef.current, node);
  }, []);

  const focusTerminal = useCallback(() => {
    const state = appStateRef.current;
    if (state.activeSession && state.attachedSession === state.activeSession) {
      terminalRef.current?.focus();
    }
  }, []);

  const clearTerminalSearch = useCallback(() => {
    setTerminalSearchOpen(false);
    setTerminalSearchQuery("");
    setTerminalSearchIndex(-1);
    setTerminalSearchCount(0);
    searchAddonRef.current?.clearDecorations();
  }, []);

  const openTerminalSearch = useCallback(() => {
    if (isCoarsePointer()) return;
    setTerminalSearchOpen(true);
    setTerminalSearchFocusNonce(value => value + 1);
  }, []);

  const closeTerminalSearch = useCallback(() => {
    clearTerminalSearch();
    terminalRef.current?.focus();
  }, [clearTerminalSearch]);

  const updateTerminalSearchQuery = useCallback(query => {
    setTerminalSearchQuery(query);
    const addon = searchAddonRef.current;
    if (!addon) return;
    if (!query) {
      addon.clearDecorations();
      setTerminalSearchIndex(-1);
      setTerminalSearchCount(0);
      return;
    }
    addon.findNext(query, {
      incremental: true,
      decorations: terminalSearchDecorations,
    });
  }, []);

  const stepTerminalSearch = useCallback(direction => {
    const addon = searchAddonRef.current;
    const query = terminalSearchQuery;
    if (!addon || !query) return;
    const options = { decorations: terminalSearchDecorations };
    if (direction === "next") addon.findNext(query, options);
    else addon.findPrevious(query, options);
  }, [terminalSearchQuery]);

  const refreshTerminal = useCallback(() => {
    const terminal = terminalRef.current;
    if (!terminal || terminal.rows <= 0) return;
    // Re-entering the shell after a page (settings/search) can leave the
    // renderer with a stale frame; force one repaint so the terminal never
    // waits for the next keystroke or click.
    terminal.refresh(0, terminal.rows - 1);
    terminal.scrollToBottom();
  }, []);

  const scheduleTerminalFit = useCallback(() => {
    // Keyboard animations resize the terminal host every frame; fitting on
    // each event makes the canvas re-render continuously and flicker. Wait
    // until the resize stream settles so a single fit lands after the
    // keyboard (or window) stops moving.
    if (fitTimerRef.current !== null) clearTimeout(fitTimerRef.current);
    fitTimerRef.current = setTimeout(() => {
      fitTimerRef.current = null;
      fitTerminal();
    }, 80);
  }, [fitTerminal]);

  const returnFocusToTerminal = useCallback(() => {
    requestAnimationFrame(() => {
      scheduleTerminalFit();
      refreshTerminal();
      if (!isCoarsePointer()) focusTerminal();
    });
  }, [focusTerminal, refreshTerminal, scheduleTerminalFit]);

  const scheduleRemoteResize = useCallback(size => {
    pendingTerminalSizeRef.current = size;
    if (resizeTimerRef.current !== null) return;
    resizeTimerRef.current = setTimeout(() => {
      resizeTimerRef.current = null;
      const next = pendingTerminalSizeRef.current;
      pendingTerminalSizeRef.current = null;
      if (!next || (next.cols === sentTerminalSizeRef.current?.cols && next.rows === sentTerminalSizeRef.current?.rows)) return;
      const state = appStateRef.current;
      if (state.activeSession
        && state.attachedSession === state.activeSession
        && focusedSessionRef.current === state.activeSession) {
        if (request("session.resize", { cols: next.cols, rows: next.rows })) {
          sentTerminalSizeRef.current = next;
        }
      }
    }, 40);
  }, [request]);

  const requestSessionFocus = useCallback((focused, size = null) => {
    const state = appStateRef.current;
    const sessionID = state.activeSession;
    if (!sessionID || state.attachedSession !== sessionID) return false;
    const params = { focused };
    if (focused) {
      const next = size || terminalSize(terminalRef.current);
      if (next) Object.assign(params, next);
    }
    const sent = request("session.focus", params, result => {
      if (appStateRef.current.activeSession !== sessionID
        || appStateRef.current.attachedSession !== sessionID) return;
      if (focused) {
        focusedSessionRef.current = result?.focused ? sessionID : null;
      } else if (focusedSessionRef.current === sessionID) {
        focusedSessionRef.current = null;
      }
    });
    if (!sent) return false;
    focusedSessionRef.current = focused ? sessionID : null;
    return true;
  }, [request]);

  const attachSession = useCallback((sessionID, force = false, autoFocus = true) => {
    if (!sessionID) return;
    const state = appStateRef.current;
    autoFocusOnAttachRef.current = autoFocus;
    if (!force && sessionID === state.attachedSession) {
      // Clicking the tab of the already-attached session is an explicit entry
      // into that shell; claim focus immediately instead of waiting for an
      // attach round-trip that will never arrive.
      refreshTerminal();
      if (isCoarsePointer()) requestSessionFocus(true);
      else terminalRef.current?.focus();
      return;
    }
    const changed = sessionID !== state.activeSession;
    state.activeSession = sessionID;
    state.attachedSession = null;
    focusedSessionRef.current = null;
    if (changed) inputQueueRef.current.clear();
    setActiveSession(sessionID);
    setAttachedSession(null);
    setEmptyOverride(null);
    sentTerminalSizeRef.current = null;
    if (changed) {
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
      setAgentViewOverride(null);
    }
    const anchor = (!changed || reanchorRequiredRef.current)
      ? null
      : recoveryAnchorRef.current;
    const message = attachTerminalMessage(sessionID, terminalRef.current, anchor);
    request(message.method, message.params, () => {
      markAttachReady(sessionID);
      // Mobile viewers need the shared PTY geometry before the first tap so
      // the shell reflows to the phone viewport. Claiming protocol focus here
      // does not focus the textarea, so the soft keyboard stays closed.
      if (isCoarsePointer()) requestSessionFocus(true);
    });
  }, [clearTerminalSearch, markAttachReady, refreshTerminal, request, requestSessionFocus]);

  const chooseWorkspace = useCallback((workspaceID, preferredSessionID = null) => {
    const state = appStateRef.current;
    const wasAttached = Boolean(state.activeSession || state.attachedSession);
    const nextTabs = workspaceTabs(state.catalog, workspaceID);
    state.activeWorkspace = workspaceID;
    state.activeSession = null;
    state.attachedSession = null;
    focusedSessionRef.current = null;
    setActiveWorkspace(workspaceID);
    setActiveSession(null);
    setAttachedSession(null);
    setEmptyOverride(null);
    setAgentViewOverride(null);
    terminalRef.current?.clear();
    clearTerminalSearch();
    recoveryAnchorRef.current = null;
    reanchorRequiredRef.current = false;
    setDrawerOpen(false);

    if (preferredSessionID) attachSession(preferredSessionID, true);
    else if (nextTabs.length) attachSession(nextTabs[0].id, true);
    else if (wasAttached) request("session.detach");
  }, [attachSession, clearTerminalSearch, request]);

  const createSession = useCallback(kind => {
    const workspaceID = appStateRef.current.activeWorkspace || selectedWorkspaceID;
    if (!workspaceID) return;
    const preset = sessionPresets.find(value => value.kind === kind) || sessionPresets[0];
    const sent = request("session.create", {
      workspace: workspaceID,
      kind: preset.kind,
      command: presetCommands[preset.kind] || "",
      title: preset.title,
    }, result => {
      const sessionID = result?.id;
      if (sessionID) attachSession(sessionID);
    });
    setEmptyOverride({
      loading: true,
      message: sent ? `Starting ${preset.title}…` : "Waiting for connection…",
    });
    if (!sent) connectionRef.current?.reconnectNow();
  }, [attachSession, presetCommands, request, selectedWorkspaceID]);

  const updatePresetCommand = useCallback((kind, command) => {
    setPresetCommands(previous => {
      const next = { ...previous, [kind]: command };
      localStorage.setItem(storageKeys.presetCommands, JSON.stringify(next));
      return next;
    });
  }, []);

  const openWorkspace = useCallback(workspaceID => {
    chooseWorkspace(workspaceID);
    createSession("shell");
  }, [chooseWorkspace, createSession]);

  const acceptRoster = useCallback(message => {
    clearMaintenanceTimeout();
    connectionRef.current?.markStable();
    const nextCatalog = buildCatalog(rosterFromMessage(message));
    const state = appStateRef.current;
    const nextWorkspaceID = resolveRestoredWorkspace(nextCatalog, state.activeWorkspace, state.activeSession);
    const nextTabs = nextWorkspaceID ? workspaceTabs(nextCatalog, nextWorkspaceID) : [];
    const activeTabWasRemoved = state.activeSession && !nextTabs.some(tab => tab.id === state.activeSession);

    state.catalog = nextCatalog;
    state.activeWorkspace = nextWorkspaceID;
    setCatalog(nextCatalog);
    setActiveWorkspace(nextWorkspaceID);
    setEmptyOverride(null);
    if (nextWorkspaceID) {
      const workspace = nextCatalog.workspaces.find(value => value.id === nextWorkspaceID);
      if (workspace && !projectDragRef.current) {
        setExpandedProjects(previous => previous.has(workspace.project)
          ? previous
          : new Set([...previous, workspace.project]));
      }
    }

    if (activeTabWasRemoved) {
      state.activeSession = null;
      state.attachedSession = null;
      focusedSessionRef.current = null;
      setActiveSession(null);
      setAttachedSession(null);
      setAgentViewOverride(null);
      terminalRef.current?.clear();
      clearTerminalSearch();
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
    }

    setConnectionStatus({ message: "Connected", online: true });
    if (state.activeSession) attachSession(state.activeSession, false, false);
    else if (nextTabs.length) attachSession(nextTabs[0].id, false, false);
    else if (activeTabWasRemoved) request("session.detach");
  }, [attachSession, clearMaintenanceTimeout, clearTerminalSearch, request]);

  const acceptMessage = useCallback(event => {
    if (event.data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(event.data);
      const decoded = decodeOutputFrame(bytes);
      const attached = appStateRef.current.attachedSession;
      if (decoded && (!attached || decoded.header.sessionID === attached)) {
        const current = recoveryAnchorRef.current;
        if (current && !snapshotPendingRef.current) {
          if (decoded.header.epoch !== current.epoch || decoded.header.sequence !== current.sequence) {
            // A gap means Host rotated the spool or the ring evicted our
            // anchor; reconnect without an anchor and reanchor from a tmux
            // snapshot instead of silently skipping or duplicating bytes.
            reanchorRequiredRef.current = true;
            connectionRef.current?.reset();
            return;
          }
          if (!batcherRef.current?.hasPending) {
            // Remember the byte position before this batch. If the renderer
            // cannot keep up and the batch is dropped, the reconnect can
            // resume exactly here instead of re-serving the whole ring.
            pendingStartAnchorRef.current = recoveryAnchorRef.current;
          }
          recoveryAnchorRef.current = {
            epoch: decoded.header.epoch,
            sequence: current.sequence + decoded.header.payloadLength,
          };
        }
        batcherRef.current?.enqueue(decoded.payload);
      } else if (decoded) {
        // A stale frame can still be queued while switching sessions. It must
        // not leak into the newly selected terminal.
      } else if (isBinaryEnvelope(bytes)) {
        // The frame claims to be a Warren envelope but cannot be decoded.
        // Rendering it would print binary garbage (DENB headers) into the
        // terminal; treat it as a protocol error and reanchor instead.
        reanchorRequiredRef.current = true;
        connectionRef.current?.reset();
      } else {
        // Legacy raw PTY payload (older daemon builds send bytes without the
        // envelope). Render it as-is.
        batcherRef.current?.enqueue(bytes);
      }
      return;
    }

    // Control messages, exit messages, and recovery markers must never jump
    // ahead of buffered terminal bytes; flush the batch first.
    batcherRef.current?.flush();

    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      setConnectionStatus({ message: "Protocol error", online: false });
      connectionRef.current?.reset();
      return;
    }

    switch (message.t) {
    case "response": {
      const handler = pendingRequestsRef.current.get(message.id);
      pendingRequestsRef.current.delete(message.id);
      if (!message.ok) {
        const detail = message.error || "Request failed";
        setConnectionStatus({ message: detail, online: false });
        setEmptyOverride({ loading: false, message: detail });
      } else {
        handler?.(message.result);
      }
      break;
    }
    case "roster":
      acceptRoster(message);
      break;
    case "attached": {
      if (appStateRef.current.activeSession !== message.session) break;
      focusedSessionRef.current = null;
      setActiveSession(message.session);
      markAttachReady(message.session);
      setEmptyOverride(null);
      if (message.reanchor) {
        terminalRef.current?.clear();
        snapshotPendingRef.current = true;
      } else {
        snapshotPendingRef.current = false;
      }
      if (Number.isFinite(message.epoch) && Number.isFinite(message.sequence)) {
        recoveryAnchorRef.current = {
          epoch: message.epoch,
          sequence: message.sequence,
        };
      } else {
        // Legacy relay: no recovery metadata, raw payloads only. Keep the
        // anchor null so frame validation stays disabled.
        recoveryAnchorRef.current = null;
      }
      reanchorRequiredRef.current = false;
      requestAnimationFrame(() => {
        fitTerminal();
        terminalRef.current?.scrollToBottom();
        const terminal = terminalRef.current;
        if (autoFocusOnAttachRef.current && terminal && document.hasFocus() && !isCoarsePointer()) {
          terminal.focus();
          if (focusedSessionRef.current !== message.session) requestSessionFocus(true);
        }
      });
      break;
    }
    case "created":
      appStateRef.current.activeSession = null;
      appStateRef.current.attachedSession = null;
      focusedSessionRef.current = null;
      setActiveSession(null);
      setAttachedSession(null);
      setEmptyOverride(null);
      attachSession(message.session);
      break;
    case "synced":
      if (appStateRef.current.attachedSession === message.session) {
        recoveryAnchorRef.current = {
          epoch: message.epoch,
          sequence: message.sequence,
        };
        snapshotPendingRef.current = false;
      }
      break;
    case "agent":
      setAgentStateBySession(previous => {
        const current = previous[message.session];
        const sameEpoch = !message.epoch || current?.epoch === message.epoch;
        const base = sameEpoch ? current.events : [];
        return {
          ...previous,
          [message.session]: {
            epoch: message.epoch,
            events: mergeAgentEvents(base, message.events),
            activity: message.activity || current?.activity || "",
          },
        };
      });
      break;
    case "runtimeMetadata":
      setCatalog(previous => {
        const session = previous.sessions.get(message.session);
        if (!session) return previous;
        const sessions = new Map(previous.sessions);
        sessions.set(message.session, {
          ...session,
          process: message.process || "",
          directory: message.directory || "",
        });
        return { ...previous, sessions };
      });
      break;
    case "sessionDeleted":
      if (appStateRef.current.activeSession === message.session) {
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        focusedSessionRef.current = null;
        setActiveSession(null);
        setAttachedSession(null);
        terminalRef.current?.clear();
        clearTerminalSearch();
        recoveryAnchorRef.current = null;
        reanchorRequiredRef.current = false;
        snapshotPendingRef.current = false;
      }
      break;
    case "exited":
      if (appStateRef.current.attachedSession === message.session) {
        appStateRef.current.activeSession = null;
        appStateRef.current.attachedSession = null;
        focusedSessionRef.current = null;
        setActiveSession(null);
        setAttachedSession(null);
        clearTerminalSearch();
        snapshotPendingRef.current = false;
        setEmptyOverride({ loading: false, message: "Session ended" });
      }
      break;
    case "error":
      setConnectionStatus({ message: message.message || "Error", online: false });
      setEmptyOverride({ loading: false, message: message.message || "Session error" });
      if (message.message === "unauthorized") connectionRef.current?.stop();
      break;
    case "maintenance":
      scheduleMaintenanceTimeout();
      setConnectionStatus({ message: message.message || "Updating Warren…", online: false });
      break;
    default:
      break;
    }
  }, [
    acceptRoster,
    attachSession,
    clearMaintenanceTimeout,
    clearTerminalSearch,
    fitTerminal,
    markAttachReady,
    requestSessionFocus,
    scheduleMaintenanceTimeout,
  ]);

  const acceptConnectionState = useCallback(state => {
    clearMaintenanceTimeout();
    if (state === "connecting") {
      setConnectionStatus({ message: "Connecting…", online: false });
      return;
    }
    if (state === "open") {
      setConnectionStatus({ message: "Authenticating…", online: false });
      return;
    }
    appStateRef.current.attachedSession = null;
    focusedSessionRef.current = null;
    setAttachedSession(null);
    sentTerminalSizeRef.current = null;
    batcherRef.current?.reset();
    // The Recovery Anchor survives a transport reconnect; only an explicit
    // reanchor decision (overflow, host adoption, evicted ring) clears it.
    setConnectionStatus({ message: "Reconnecting…", online: false });
  }, [clearMaintenanceTimeout]);

  messageHandlerRef.current = acceptMessage;
  connectionStateHandlerRef.current = acceptConnectionState;

  useEffect(() => clearMaintenanceTimeout, [clearMaintenanceTimeout]);

  useEffect(() => {
    const terminalHost = terminalHostRef.current;
    if (!terminalHost) return undefined;

    const terminal = new Terminal({
      theme: terminalTheme,
      fontFamily,
      fontSize,
      lineHeight: 1.12,
      cursorBlink: true,
      scrollback: 20000,
      allowTransparency: false,
      allowProposedApi: true,
    });
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.loadAddon(new Unicode11Addon());
    terminal.unicode.activeVersion = "11";
    terminal.open(terminalHost);
    terminalRef.current = terminal;
    fitAddonRef.current = fitAddon;
    const stopTouchScroll = enableTerminalTouchScroll(terminal, terminalHost);
    const textarea = terminal.textarea;
    if (textarea) {
      // Hint mobile keyboards toward the English layout by default; the user
      // can still switch IMEs when they actually need CJK input.
      textarea.lang = "en-US";
      textarea.setAttribute("autocorrect", "off");
      textarea.setAttribute("autocapitalize", "off");
      textarea.setAttribute("spellcheck", "false");
      textarea.setAttribute("autocomplete", "off");
    }
    // Mobile GPUs churn through WebGL contexts while the keyboard resizes
    // the terminal, which reads as flicker. The DOM renderer is steadier on
    // touch devices; desktop keeps WebGL for large outputs.
    if (!isCoarsePointer()) {
      try {
        const webglAddon = new WebglAddon();
        terminal.loadAddon(webglAddon);
        webglAddon.onContextLoss(() => {
          // Desktop GPUs can still drop the context under memory pressure.
          // Dispose and let xterm fall back to its DOM renderer.
          webglAddonRef.current?.dispose();
          webglAddonRef.current = null;
        });
        webglAddonRef.current = webglAddon;
      } catch {
        // WebGL is optional; older browsers and some embedded webviews keep
        // the DOM renderer.
      }
    }
    const searchAddon = new SearchAddon({ highlightLimit: 2000 });
    terminal.loadAddon(searchAddon);
    searchAddonRef.current = searchAddon;
    const searchResultsSubscription = searchAddon.onDidChangeResults(({ resultIndex, resultCount }) => {
      setTerminalSearchIndex(resultIndex);
      setTerminalSearchCount(resultCount);
    });
    let overflowWhileHidden = false;
    const rewindAndReset = () => {
      const start = pendingStartAnchorRef.current;
      if (start) recoveryAnchorRef.current = start;
      else reanchorRequiredRef.current = true;
      connectionRef.current?.reset();
    };
    const batcher = new OutputBatcher({
      write: bytes => {
        const buffer = terminal.buffer.active;
        const followsOutput = buffer.viewportY === buffer.baseY;
        terminal.write(bytes);
        // Keep a terminal that is already pinned to the bottom glued to new
        // output; a user who scrolled up keeps their place.
        if (followsOutput) terminal.scrollToBottom();
      },
      // Match the daemon's output ring retention so a dropped batch can
      // always be replayed from its anchor instead of forcing a reanchor.
      maxPending: 8 * 1024 * 1024,
      onOverflow: () => {
        // A hidden tab has no rAF ticks to drain the batcher. Reconnecting
        // there just re-serves the retained tail and overflows again, which
        // reads as a "Connecting…" loop; reset once when the tab is visible.
        if (document.hidden) {
          overflowWhileHidden = true;
          return;
        }
        rewindAndReset();
      },
    });
    batcherRef.current = batcher;
    // xterm opens at its fallback 80x24 grid. Fit once synchronously and once
    // on the next frame so the first focus claim carries the real viewport,
    // even when fonts/layout settle after the DOM mount.
    fitTerminalToHost(fitAddon, terminalHost);
    requestAnimationFrame(() => {
      if (terminalRef.current === terminal) fitTerminalToHost(fitAddon, terminalHost);
    });
    waitForTerminalFont({ fontFamily, fontSize }).then(() => {
      if (terminalRef.current === terminal) scheduleTerminalFit();
    });

    // Mobile soft keyboards and CJK IMEs can fire xterm onData twice for the
    // same keystroke (compositionend plus the following input event). Track
    // composition state and drop exact duplicates inside a short window.
    const isTouch = isCoarsePointer();
    const deduper = new MobileInputDeduper({ isTouch });
    const onCompositionStart = () => {
      deduper.onCompositionStart();
    };
    const onCompositionEnd = () => {
      deduper.onCompositionEnd();
    };
    textarea?.addEventListener("compositionstart", onCompositionStart);
    textarea?.addEventListener("compositionend", onCompositionEnd);
    const sendDeduped = data => {
      if (!data) return;
      if (deduper.shouldSend(data)) sendInput(data);
    };
    const dataSubscription = terminal.onData(sendDeduped);
    const onTextareaInput = event => {
      // Mobile Chinese keyboards can commit full-width punctuation as an
      // `insertCompositionText`/`insertText` input event that xterm ignores
      // (it only forwards keydown and plain insertText). Forward the final
      // committed data ourselves; the deduper absorbs any xterm echo.
      if (deduper.isComposing || !event.data) return;
      const inputType = event.inputType || "";
      // Keep paste/drop/autofill on xterm's own handler so bracketed paste
      // and quoting semantics stay intact.
      if (inputType === "insertFromPaste"
        || inputType === "insertFromDrop"
        || inputType === "insertFromYank"
        || inputType === "insertReplacementText"
        || inputType.startsWith("history")
        || inputType.startsWith("delete")) {
        return;
      }
      sendDeduped(event.data);
    };
    textarea?.addEventListener("input", onTextareaInput);
    const resizeSubscription = terminal.onResize(scheduleRemoteResize);
    const onTerminalFocus = () => requestSessionFocus(true);
    const onTerminalBlur = () => {
      // Touch devices keep the protocol focus after the keyboard closes so
      // later layout changes (rotation, keyboard collapse) still reflow the
      // shell while the user is just viewing.
      if (!isCoarsePointer()) requestSessionFocus(false);
    };
    const copySelectionOnMouseUp = event => {
      // Ghostty on macOS copies a completed selection to the clipboard; mirror
      // that behavior for web mouse users. Touch selection is left to the
      // platform because automatic copying is fragile on mobile.
      if (event.pointerType !== "mouse" || !terminal.hasSelection()) return;
      const text = terminal.getSelection();
      if (text && navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
    };
    terminal.element?.addEventListener("mouseup", copySelectionOnMouseUp);
    terminal.textarea?.addEventListener("focus", onTerminalFocus);
    terminal.textarea?.addEventListener("blur", onTerminalBlur);
    const releaseWindowFocus = () => {
      if (!isCoarsePointer()) requestSessionFocus(false);
    };
    const claimWindowFocus = () => {
      if (terminal.element?.contains(document.activeElement)) requestSessionFocus(true);
    };
    const handleVisibilityChange = () => {
      if (document.hidden) releaseWindowFocus();
      else claimWindowFocus();
    };
    window.addEventListener("blur", releaseWindowFocus);
    window.addEventListener("focus", claimWindowFocus);
    document.addEventListener("visibilitychange", handleVisibilityChange);
    const resizeObserver = new ResizeObserver(() => scheduleTerminalFit());
    resizeObserver.observe(terminalHost);
    const onVisibilityChange = () => {
      if (document.hidden) return;
      batcherRef.current?.wake();
      if (overflowWhileHidden) {
        overflowWhileHidden = false;
        rewindAndReset();
      }
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      dataSubscription.dispose();
      resizeSubscription.dispose();
      searchResultsSubscription.dispose();
      terminal.element?.removeEventListener("mouseup", copySelectionOnMouseUp);
      textarea?.removeEventListener("compositionstart", onCompositionStart);
      textarea?.removeEventListener("compositionend", onCompositionEnd);
      textarea?.removeEventListener("input", onTextareaInput);
      terminal.textarea?.removeEventListener("focus", onTerminalFocus);
      terminal.textarea?.removeEventListener("blur", onTerminalBlur);
      window.removeEventListener("blur", releaseWindowFocus);
      window.removeEventListener("focus", claimWindowFocus);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      resizeObserver.disconnect();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      stopTouchScroll();
      if (fitTimerRef.current !== null) {
        clearTimeout(fitTimerRef.current);
        fitTimerRef.current = null;
      }
      webglAddonRef.current?.dispose();
      webglAddonRef.current = null;
      searchAddon.dispose();
      searchAddonRef.current = null;
      terminal.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      batcher.dispose();
      batcherRef.current = null;
    };
  }, [requestSessionFocus, scheduleRemoteResize, scheduleTerminalFit, sendInput]);

  useEffect(() => {
    const terminal = terminalRef.current;
    if (!terminal) return;
    terminal.options.fontFamily = fontFamily;
    terminal.options.fontSize = fontSize;
    scheduleTerminalFit();
    waitForTerminalFont({ fontFamily, fontSize }).then(() => {
      if (terminalRef.current === terminal) scheduleTerminalFit();
    });
  }, [fontFamily, fontSize, scheduleTerminalFit]);

  useEffect(() => {
    if (activeWorkspace !== selectedWorkspaceID) setActiveWorkspace(selectedWorkspaceID);
  }, [activeWorkspace, selectedWorkspaceID]);

  useEffect(() => {
    if (!selectedWorkspace || projectDragRef.current) return;
    setExpandedProjects(previous => previous.has(selectedWorkspace.project)
      ? previous
      : new Set([...previous, selectedWorkspace.project]));
  }, [selectedWorkspace]);

  useEffect(() => {
    localStorage.setItem(storageKeys.activeWorkspace, selectedWorkspaceID || "");
  }, [selectedWorkspaceID]);

  useEffect(() => {
    localStorage.setItem(storageKeys.activeSession, activeSession || "");
  }, [activeSession]);

  useEffect(() => {
    localStorage.setItem(storageKeys.expandedProjects, JSON.stringify([...expandedProjects]));
  }, [expandedProjects]);

  useEffect(() => {
    localStorage.setItem(storageKeys.fontFamily, fontFamily);
    localStorage.setItem(storageKeys.fontSize, String(fontSize));
  }, [fontFamily, fontSize]);

  useEffect(() => {
    localStorage.setItem(storageKeys.titleTemplate, titleTemplate);
  }, [titleTemplate]);

  useEffect(() => {
    const connection = new WarrenConnection({
      url: webSocketURL(),
      token: runtime.token,
      onMessage: event => messageHandlerRef.current(event),
      onState: state => connectionStateHandlerRef.current(state),
    });
    connectionRef.current = connection;
    connection.start();
    return () => {
      connection.stop();
      connectionRef.current = null;
    };
  }, []);

  useEffect(() => {
    const reconnect = () => connectionRef.current?.reconnectNow();
    window.addEventListener("online", reconnect);
    return () => window.removeEventListener("online", reconnect);
  }, []);

  useEffect(() => {
    if ("serviceWorker" in navigator && location.protocol !== "file:") {
      navigator.serviceWorker.register(serviceWorkerURL()).catch(() => {});
    }
  }, []);

  const toggleProject = useCallback(projectID => {
    setExpandedProjects(previous => {
      const next = new Set(previous);
      if (next.has(projectID)) next.delete(projectID);
      else next.add(projectID);
      return next;
    });
  }, []);

  const closeContextMenu = useCallback(() => setContextMenu(null), []);

  const showContextMenu = useCallback((event, items) => {
    event.preventDefault();
    setContextMenu({ x: event.clientX, y: event.clientY, items });
  }, []);

  const renameProject = useCallback(project => {
    const value = window.prompt("Rename project", project.name || "");
    if (value?.trim()) {
      request("project.rename", { id: project.id, name: value.trim() });
    }
  }, [request]);

  const renameWorkspace = useCallback(workspace => {
    const value = window.prompt("Rename workspace", workspace.name || "");
    if (value?.trim()) {
      request("workspace.rename", { id: workspace.id, name: value.trim() });
    }
  }, [request]);

  const renameSession = useCallback(session => {
    const current = session.customTitle || session.title || "";
    const value = window.prompt("Rename session", current);
    if (value?.trim()) {
      request("session.rename", { id: session.id, title: value.trim() });
    }
  }, [request]);

  const toggleProjectPin = useCallback(project => {
    request("project.pin", { id: project.id, pinned: !project.pinned });
  }, [request]);

  const toggleWorkspacePin = useCallback(workspace => {
    request("workspace.pin", { id: workspace.id, pinned: !workspace.pinned });
  }, [request]);

  const toggleSessionPin = useCallback(session => {
    request("session.pin", { id: session.id, pinned: !session.pinned });
  }, [request]);

  const projectContextMenu = useCallback((event, project) => {
    showContextMenu(event, [
      {
        label: project.pinned ? "Unpin project" : "Pin project",
        action: () => toggleProjectPin(project),
      },
      { label: "Rename project", action: () => renameProject(project) },
    ]);
  }, [renameProject, showContextMenu, toggleProjectPin]);

  const workspaceContextMenu = useCallback((event, workspace) => {
    showContextMenu(event, [
      {
        label: workspace.pinned ? "Unpin workspace" : "Pin workspace",
        action: () => toggleWorkspacePin(workspace),
      },
      { label: "Rename workspace", action: () => renameWorkspace(workspace) },
    ]);
  }, [renameWorkspace, showContextMenu, toggleWorkspacePin]);

  const deleteSession = useCallback(session => {
    const label = session.title || session.id;
    if (!window.confirm(`Delete session "${label}"? This kills its terminal process.`)) return;
    request("session.delete", { id: session.id }, () => {
      // If the deleted session owns the visible terminal, clear it right away
      // instead of waiting for the next roster broadcast. The empty-state
      // overlay is opaque, but the xterm surface behind it must not keep the
      // last agent screen.
      const current = appStateRef.current;
      if (current.activeSession === session.id || current.attachedSession === session.id) {
        terminalRef.current?.clear();
        recoveryAnchorRef.current = null;
        reanchorRequiredRef.current = false;
      }
    });
  }, [request]);

  const sessionContextMenu = useCallback((event, session) => {
    showContextMenu(event, [
      {
        label: session.pinned ? "Unpin session" : "Pin session",
        action: () => toggleSessionPin(session),
      },
      { label: "Rename session", action: () => renameSession(session) },
      { label: "Delete session", danger: true, action: () => deleteSession(session) },
    ]);
  }, [deleteSession, renameSession, showContextMenu, toggleSessionPin]);

  const beginProjectDrag = useCallback(previousExpanded => {
    projectDragRef.current = { previousExpanded };
    setExpandedProjects(new Set());
  }, []);

  const endProjectDrag = useCallback(() => {
    const previous = projectDragRef.current?.previousExpanded;
    projectDragRef.current = null;
    if (previous) setExpandedProjects(previous);
  }, []);

  const moveProject = useCallback((projectID, beforeProjectID) => {
    request("project.move", {
      id: projectID,
      ...(beforeProjectID ? { before: beforeProjectID } : {}),
    });
    setCatalog(current => moveInCatalog(current, "projects", projectID, beforeProjectID));
  }, [request]);

  const moveWorkspace = useCallback((workspaceID, beforeWorkspaceID) => {
    request("workspace.move", {
      id: workspaceID,
      ...(beforeWorkspaceID ? { before: beforeWorkspaceID } : {}),
    });
    setCatalog(current => moveInCatalog(current, "workspaces", workspaceID, beforeWorkspaceID));
  }, [request]);

  const openSettings = useCallback(() => {
    navigationBeforeSettingsRef.current = captureNavigationPosition(appStateRef.current);
    setSearchOpen(false);
    clearTerminalSearch();
    setSettingsOpen(true);
  }, [clearTerminalSearch]);

  const closeSettings = useCallback(() => {
    const previousPosition = navigationBeforeSettingsRef.current;
    navigationBeforeSettingsRef.current = null;
    const restoredPosition = restoreNavigationPosition(previousPosition, appStateRef.current.catalog);
    const state = appStateRef.current;
    const sessionWasInvalidated = Boolean(previousPosition?.sessionID && !restoredPosition?.sessionID);
    if (restoredPosition && (
      restoredPosition.workspaceID !== state.activeWorkspace
      || restoredPosition.sessionID !== state.activeSession
      || state.attachedSession !== restoredPosition.sessionID
      || sessionWasInvalidated
    )) {
      chooseWorkspace(restoredPosition.workspaceID, restoredPosition.sessionID);
    }
    setSettingsOpen(false);
    returnFocusToTerminal();
  }, [chooseWorkspace, returnFocusToTerminal]);

  const closeSearch = useCallback(() => {
    setSearchOpen(false);
    returnFocusToTerminal();
  }, [returnFocusToTerminal]);

  useEffect(() => {
    const handleKeyDown = event => {
      const modifier = event.metaKey || event.ctrlKey;
      if (event.key === "Escape" && terminalSearchOpen) {
        closeTerminalSearch();
        return;
      }
      if (event.key === "Escape" && searchOpen) {
        closeSearch();
        return;
      }
      if (event.key === "Escape" && settingsOpen) {
        closeSettings();
        return;
      }
      if (settingsOpen || searchOpen || !modifier) return;
      if (event.key.toLowerCase() === "k") {
        event.preventDefault();
        setSearchOpen(true);
      } else if (event.key.toLowerCase() === "f") {
        event.preventDefault();
        openTerminalSearch();
      } else if (event.key === ",") {
        event.preventDefault();
        openSettings();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [searchOpen, settingsOpen, terminalSearchOpen, openSettings, closeSearch, closeSettings, closeTerminalSearch, openTerminalSearch]);

  const chooseSearchWorkspace = useCallback(workspaceID => {
    closeSearch();
    chooseWorkspace(workspaceID);
  }, [chooseWorkspace, closeSearch]);

  const chooseSearchProject = useCallback(projectID => {
    const workspace = catalog.workspacesByProject.get(projectID)?.[0];
    if (workspace) chooseSearchWorkspace(workspace.id);
  }, [catalog.workspacesByProject, chooseSearchWorkspace]);

  const updateFontFamily = useCallback(value => {
    setFontFamily(value.trim() || defaultFontFamily);
  }, []);

  const updateFontSize = useCallback(value => {
    setFontSize(clamp(Number(value) || defaultFontSize, 8, 32));
  }, []);

  const updateTitleTemplate = useCallback(value => {
    setTitleTemplate(value.trim() || defaultTitleTemplate);
  }, []);

  const appendPlaceholder = useCallback(placeholder => {
    setTitleTemplate(previous => `${previous}${previous && !previous.endsWith(" ") ? " " : ""}${placeholder}`);
  }, []);

  const restoreDefaults = useCallback(() => {
    setTitleTemplate(defaultTitleTemplate);
    setFontFamily(defaultFontFamily);
    setFontSize(defaultFontSize);
    setPresetCommands({ ...defaultPresetCommands });
    localStorage.removeItem(storageKeys.presetCommands);
  }, []);

  const selectedAgentEvents = selectedSession
    ? agentStateBySession[selectedSession.id]?.events || []
    : [];
  const agentModel = useMemo(() => {
    for (let index = selectedAgentEvents.length - 1; index >= 0; index--) {
      if (selectedAgentEvents[index].model) return selectedAgentEvents[index].model;
    }
    return "";
  }, [selectedAgentEvents]);
  const isAgentSession = Boolean(
    selectedSession
      && (selectedSession.kind === "codex" || selectedSession.kind === "claude"),
  );
  const agentViewActive = Boolean(
    isAgentSession
      && agentViewOverride !== "terminal",
  );

  return (
    <>
      <div className={`app${drawerOpen ? " drawer-open" : ""}`} hidden={settingsOpen}>
        <Sidebar
          catalog={catalog}
          activeWorkspace={selectedWorkspaceID}
          expandedProjects={expandedProjects}
          tabsForWorkspace={workspaceID => workspaceTabs(catalog, workspaceID)}
          connection={connectionStatus}
          onToggleProject={toggleProject}
          onChooseWorkspace={chooseWorkspace}
          onOpenWorkspace={openWorkspace}
          onNewSession={() => createSession("shell")}
          onOpenSettings={openSettings}
          onProjectContextMenu={projectContextMenu}
          onWorkspaceContextMenu={workspaceContextMenu}
          onMoveProject={moveProject}
          onMoveWorkspace={moveWorkspace}
          onBeginProjectDrag={beginProjectDrag}
          onEndProjectDrag={endProjectDrag}
        />
        <button type="button" className="backdrop" aria-label="Close navigation" onClick={() => setDrawerOpen(false)} />
        <main className="main">
          <TopBar
            tabs={tabs}
            activeSession={activeSession}
            workspace={selectedWorkspace}
            onAttachSession={attachSession}
            onNewSession={() => createSession("shell")}
            onOpenMenu={() => setDrawerOpen(true)}
            onOpenSearch={() => setSearchOpen(true)}
            onTabContextMenu={sessionContextMenu}
          />
          <PresetBar presets={sessionPresets} onCreateSession={createSession} />
          <div className="pane-title">
            <span>{paneTitle}</span>
            {isAgentSession && (agentModel || selectedSession?.agentSessionId) && (
              <span className="pane-agent-meta">
                {agentModel && <span className="pane-agent-model">{agentModel}</span>}
                {selectedSession?.agentSessionId && <code className="pane-agent-session">{shortSessionID(selectedSession.agentSessionId)}</code>}
              </span>
            )}
            {isAgentSession && (agentViewActive ? (
              <button type="button" className="pane-action" onClick={() => setAgentViewOverride("terminal")}>
                Terminal
              </button>
            ) : (
              <button type="button" className="pane-action" onClick={() => setAgentViewOverride("agent")}>
                Agent
              </button>
            ))}
          </div>
          <section
            className="terminal-shell"
            aria-label="Terminal"
            onPointerDown={event => {
              if (event.pointerType === "mouse") focusTerminal();
            }}
            onClick={focusTerminal}
          >
            <div id="terminal" ref={terminalHostRef} hidden={agentViewActive} />
            {agentViewActive && (
              <AgentView
                session={selectedSession}
                events={selectedAgentEvents}
                onSend={sendAgentInput}
              />
            )}
            <TerminalSearch
              open={terminalSearchOpen}
              query={terminalSearchQuery}
              resultIndex={terminalSearchIndex}
              resultCount={terminalSearchCount}
              focusNonce={terminalSearchFocusNonce}
              onQueryChange={updateTerminalSearchQuery}
              onNext={() => stepTerminalSearch("next")}
              onPrevious={() => stepTerminalSearch("previous")}
              onClose={closeTerminalSearch}
            />
            <EmptyTerminal
              activeWorkspace={selectedWorkspaceID}
              activeSession={activeSession}
              attachedSession={attachedSession}
              tabCount={tabs.length}
              projectCount={catalog.projects.length}
              override={emptyOverride}
              onNewSession={() => createSession("shell")}
            />
          </section>
          {!agentViewActive && <MobileKeys onInput={sendInput} />}
        </main>
      </div>
      <SettingsPage
        open={settingsOpen}
        fontFamily={fontFamily}
        fontSize={fontSize}
        titleTemplate={titleTemplate}
        presetCommands={presetCommands}
        titlePreview={titlePreview}
        placeholders={Object.entries(titlePlaceholders)}
        onClose={closeSettings}
        onFontFamilyChange={updateFontFamily}
        onFontSizeChange={updateFontSize}
        onTitleTemplateChange={updateTitleTemplate}
        onPresetCommandChange={updatePresetCommand}
        onAppendPlaceholder={appendPlaceholder}
        onRestore={restoreDefaults}
      />
      <SearchPanel
        open={searchOpen}
        query={searchQuery}
        catalog={catalog}
        onQueryChange={setSearchQuery}
        onClose={closeSearch}
        onChooseWorkspace={chooseSearchWorkspace}
        onChooseProject={chooseSearchProject}
      />
      <ContextMenu menu={contextMenu} onClose={closeContextMenu} />
    </>
  );
}

function loadSet(key) {
  try {
    return new Set(JSON.parse(localStorage.getItem(key) || "[]"));
  } catch {
    return new Set();
  }
}

function loadPresetCommands() {
  try {
    return { ...defaultPresetCommands, ...JSON.parse(localStorage.getItem(storageKeys.presetCommands) || "{}") };
  } catch {
    return { ...defaultPresetCommands };
  }
}

function shortSessionID(id) {
  return id.length > 18 ? `${id.slice(0, 8)}…${id.slice(-6)}` : id;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
