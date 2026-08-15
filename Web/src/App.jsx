import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

import { buildCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import { RelayConnection } from "./connection.js";
import {
  captureNavigationPosition,
  resolveRestoredWorkspace,
  restoreNavigationPosition,
} from "./navigation.js";
import { runtime, serviceWorkerURL, webSocketURL } from "./runtime.js";
import { defaultTitleTemplate, renderTerminalTitle, titlePlaceholders } from "./title.js";
import { attachTerminalMessage, fitTerminalToHost, terminalSize } from "./terminal.js";
import { InputQueue } from "./input.js";
import { OutputBatcher } from "./output.js";
import { decodeOutputFrame, isBinaryEnvelope } from "./wire.js";
import {
  EmptyTerminal,
  MobileKeys,
  PresetBar,
  SearchPanel,
  SettingsPage,
  Sidebar,
  TopBar,
} from "./components.jsx";

const storageKeys = {
  activeWorkspace: "warren.activeWorkspace",
  activeSession: "warren.activeSession",
  expandedProjects: "warren.expandedProjects",
  fontFamily: "warren.terminalFontFamily",
  fontSize: "warren.terminalFontSize",
  titleTemplate: "warren.terminalTitleTemplate",
};

const defaultFontFamily = 'ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace';
const defaultFontSize = matchMedia("(max-width: 760px)").matches ? 12 : 13;
const pendingInputLimit = 64 * 1024;
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
const sessionPresets = [
  { kind: "shell", label: "Shell", title: "Shell" },
  { kind: "claude", label: "Claude", title: "Claude Code", command: "claude" },
  { kind: "codex", label: "Codex", title: "Codex", command: "codex --dangerously-bypass-hook-trust" },
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
  const [connectionStatus, setConnectionStatus] = useState({ message: "Connecting…", online: false });
  const [emptyOverride, setEmptyOverride] = useState(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");

  const connectionRef = useRef(null);
  const terminalHostRef = useRef(null);
  const terminalRef = useRef(null);
  const fitAddonRef = useRef(null);
  const webglAddonRef = useRef(null);
  const fitFrameRef = useRef(null);
  const resizeTimerRef = useRef(null);
  const pendingTerminalSizeRef = useRef(null);
  const sentTerminalSizeRef = useRef(null);
  const focusedSessionRef = useRef(null);
  const batcherRef = useRef(null);
  const recoveryAnchorRef = useRef(null);
  const reanchorRequiredRef = useRef(false);
  const snapshotPendingRef = useRef(false);
  const messageHandlerRef = useRef(() => {});
  const connectionStateHandlerRef = useRef(() => {});
  const appStateRef = useRef({});
  const pendingRequestsRef = useRef(new Map());
  const inputQueueRef = useRef(null);
  const navigationBeforeSettingsRef = useRef(null);
  if (inputQueueRef.current === null) {
    inputQueueRef.current = new InputQueue({
      limit: pendingInputLimit,
      send: data => Boolean(connectionRef.current?.sendBinary(data)),
      onSendFailure: () => connectionRef.current?.reconnectNow(),
    });
  }

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
    terminalRef.current?.focus();
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

  const fitTerminal = useCallback(() => {
    fitFrameRef.current = null;
    const node = terminalHostRef.current;
    fitTerminalToHost(fitAddonRef.current, node);
  }, []);

  const focusTerminal = useCallback(() => {
    const state = appStateRef.current;
    if (state.activeSession && state.attachedSession === state.activeSession) {
      terminalRef.current?.focus();
    }
  }, []);

  const scheduleTerminalFit = useCallback(() => {
    if (fitFrameRef.current !== null) return;
    fitFrameRef.current = requestAnimationFrame(fitTerminal);
  }, [fitTerminal]);

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

  const attachSession = useCallback((sessionID, force = false) => {
    if (!sessionID) return;
    const state = appStateRef.current;
    if (!force && sessionID === state.attachedSession) return;
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
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
    }
    const anchor = (!changed || reanchorRequiredRef.current)
      ? null
      : recoveryAnchorRef.current;
    const message = attachTerminalMessage(sessionID, terminalRef.current, anchor);
    request(message.method, message.params, () => markAttachReady(sessionID));
  }, [markAttachReady, request]);

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
    terminalRef.current?.clear();
    recoveryAnchorRef.current = null;
    reanchorRequiredRef.current = false;
    setDrawerOpen(false);

    if (preferredSessionID) attachSession(preferredSessionID, true);
    else if (nextTabs.length) attachSession(nextTabs[0].id, true);
    else if (wasAttached) request("session.detach");
  }, [attachSession, request]);

  const switchTab = useCallback(direction => {
    const state = appStateRef.current;
    const workspaceID = state.activeWorkspace;
    if (!workspaceID) return;
    const nextTabs = workspaceTabs(state.catalog, workspaceID);
    if (nextTabs.length < 2) return;
    const currentIndex = nextTabs.findIndex(tab => tab.id === state.activeSession);
    const nextIndex = currentIndex === -1
      ? 0
      : (currentIndex + direction + nextTabs.length) % nextTabs.length;
    attachSession(nextTabs[nextIndex].id);
  }, [attachSession]);

  const createSession = useCallback(kind => {
    const workspaceID = appStateRef.current.activeWorkspace;
    if (!workspaceID) return;
    const preset = sessionPresets.find(value => value.kind === kind) || sessionPresets[0];
    const sent = request("session.create", {
      workspace: workspaceID,
      kind: preset.kind,
      command: preset.command || "",
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
  }, [attachSession, request]);

  const openWorkspace = useCallback(workspaceID => {
    chooseWorkspace(workspaceID);
    createSession("shell");
  }, [chooseWorkspace, createSession]);

  const acceptRoster = useCallback(message => {
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
      if (workspace) {
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
      terminalRef.current?.clear();
      recoveryAnchorRef.current = null;
      reanchorRequiredRef.current = false;
    }

    setConnectionStatus({ message: "Connected", online: true });
    if (state.activeSession) attachSession(state.activeSession);
    else if (nextTabs.length) attachSession(nextTabs[0].id);
    else if (activeTabWasRemoved) request("session.detach");
  }, [attachSession, request]);

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
        // Legacy raw PTY payload (macOS WebRelay sends bytes without the
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
        const terminal = terminalRef.current;
        if (terminal && document.hasFocus()) {
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
        snapshotPendingRef.current = false;
        setEmptyOverride({ loading: false, message: "Session ended" });
      }
      break;
    case "error":
      setConnectionStatus({ message: message.message || "Error", online: false });
      setEmptyOverride({ loading: false, message: message.message || "Session error" });
      if (message.message === "unauthorized") connectionRef.current?.stop();
      break;
    default:
      break;
    }
  }, [acceptRoster, attachSession, fitTerminal, markAttachReady, requestSessionFocus]);

  const acceptConnectionState = useCallback(state => {
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
  }, []);

  messageHandlerRef.current = acceptMessage;
  connectionStateHandlerRef.current = acceptConnectionState;

  useEffect(() => {
    const terminalHost = terminalHostRef.current;
    if (!terminalHost) return undefined;

    const terminal = new Terminal({
      theme: {
        background: "#151110",
        foreground: "#eae8e6",
        cursor: "#eae8e6",
        selectionBackground: "#3a3837",
      },
      fontFamily,
      fontSize,
      lineHeight: 1.12,
      cursorBlink: true,
      scrollback: 20000,
      allowTransparency: false,
    });
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(terminalHost);
    terminalRef.current = terminal;
    fitAddonRef.current = fitAddon;
    try {
      const webglAddon = new WebglAddon();
      terminal.loadAddon(webglAddon);
      webglAddon.onContextLoss(() => {
        // Mobile GPUs can drop the context under memory pressure. Dispose and
        // let xterm fall back to its DOM renderer instead of freezing.
        webglAddonRef.current?.dispose();
        webglAddonRef.current = null;
      });
      webglAddonRef.current = webglAddon;
    } catch {
      // WebGL is optional; older browsers and some embedded webviews keep the
      // DOM renderer.
    }
    const batcher = new OutputBatcher({
      write: bytes => terminal.write(bytes),
      onOverflow: () => {
        reanchorRequiredRef.current = true;
        connectionRef.current?.reset();
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

    const dataSubscription = terminal.onData(sendInput);
    const resizeSubscription = terminal.onResize(scheduleRemoteResize);
    const onTerminalFocus = () => requestSessionFocus(true);
    const onTerminalBlur = () => requestSessionFocus(false);
    terminal.textarea?.addEventListener("focus", onTerminalFocus);
    terminal.textarea?.addEventListener("blur", onTerminalBlur);
    const releaseWindowFocus = () => requestSessionFocus(false);
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
      if (!document.hidden) batcherRef.current?.wake();
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      dataSubscription.dispose();
      resizeSubscription.dispose();
      terminal.textarea?.removeEventListener("focus", onTerminalFocus);
      terminal.textarea?.removeEventListener("blur", onTerminalBlur);
      window.removeEventListener("blur", releaseWindowFocus);
      window.removeEventListener("focus", claimWindowFocus);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      resizeObserver.disconnect();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      webglAddonRef.current?.dispose();
      webglAddonRef.current = null;
      terminal.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      batcher.dispose();
      batcherRef.current = null;
    };
  }, [requestSessionFocus, scheduleRemoteResize, scheduleTerminalFit, sendInput]);

  useEffect(() => {
    if (!terminalRef.current) return;
    terminalRef.current.options.fontFamily = fontFamily;
    terminalRef.current.options.fontSize = fontSize;
    scheduleTerminalFit();
  }, [fontFamily, fontSize, scheduleTerminalFit]);

  useEffect(() => {
    if (activeWorkspace !== selectedWorkspaceID) setActiveWorkspace(selectedWorkspaceID);
  }, [activeWorkspace, selectedWorkspaceID]);

  useEffect(() => {
    if (!selectedWorkspace) return;
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
    const connection = new RelayConnection({
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

  const openSettings = useCallback(() => {
    navigationBeforeSettingsRef.current = captureNavigationPosition(appStateRef.current);
    setSearchOpen(false);
    setSettingsOpen(true);
  }, []);

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
    scheduleTerminalFit();
  }, [chooseWorkspace, scheduleTerminalFit]);

  useEffect(() => {
    const handleKeyDown = event => {
      const modifier = event.metaKey || event.ctrlKey;
      if (event.key === "Escape" && searchOpen) {
        setSearchOpen(false);
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
      } else if (event.key === ",") {
        event.preventDefault();
        openSettings();
      } else if (event.key.toLowerCase() === "x") {
        event.preventDefault();
        switchTab(event.shiftKey ? -1 : 1);
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [searchOpen, settingsOpen, openSettings, closeSettings, switchTab]);

  const chooseSearchWorkspace = useCallback(workspaceID => {
    setSearchOpen(false);
    chooseWorkspace(workspaceID);
  }, [chooseWorkspace]);

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
  }, []);

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
        />
        <button type="button" className="backdrop" aria-label="Close navigation" onClick={() => setDrawerOpen(false)} />
        <main className="main">
          <TopBar
            tabs={tabs}
            activeSession={activeSession}
            onAttachSession={attachSession}
            onNewSession={() => createSession("shell")}
            onOpenMenu={() => setDrawerOpen(true)}
            onOpenSearch={() => setSearchOpen(true)}
          />
          <PresetBar presets={sessionPresets} onCreateSession={createSession} />
          <div className="pane-title"><span>{paneTitle}</span></div>
          <section className="terminal-shell" aria-label="Terminal" onPointerDown={focusTerminal}>
            <div id="terminal" ref={terminalHostRef} />
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
          <MobileKeys onInput={sendInput} />
        </main>
      </div>
      <SettingsPage
        open={settingsOpen}
        fontFamily={fontFamily}
        fontSize={fontSize}
        titleTemplate={titleTemplate}
        titlePreview={titlePreview}
        placeholders={Object.entries(titlePlaceholders)}
        onClose={closeSettings}
        onFontFamilyChange={updateFontFamily}
        onFontSizeChange={updateFontSize}
        onTitleTemplateChange={updateTitleTemplate}
        onAppendPlaceholder={appendPlaceholder}
        onRestore={restoreDefaults}
      />
      <SearchPanel
        open={searchOpen}
        query={searchQuery}
        catalog={catalog}
        onQueryChange={setSearchQuery}
        onClose={() => setSearchOpen(false)}
        onChooseWorkspace={chooseSearchWorkspace}
        onChooseProject={chooseSearchProject}
      />
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

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
