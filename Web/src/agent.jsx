import { useEffect, useLayoutEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { groupAgentEvents } from "./agent.js";
import { sessionDisplayTitle } from "./title.js";

export function AgentView({
  session,
  events = [],
  onSend,
  ready = true,
  hasMore = false,
  loadingMore = false,
  onLoadMore = () => {},
}) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const loadMoreRef = useRef(null);
  const pinnedSessionIDRef = useRef(null);
  const pinToBottomRef = useRef(true);
  const anchorElementRef = useRef(null);
  const anchorOffsetRef = useRef(null);
  const skipFollowRef = useRef(false);
  const [draft, setDraft] = useState("");
  const blocks = groupAgentEvents(events);
  const displayTitle = sessionDisplayTitle(session) || "Agent";

  useLayoutEffect(() => {
    const list = listRef.current;
    if (!list) return;
    // A fresh agent view (new session, history reset, or re-entering agent
    // mode) should open at the latest messages instead of the top. History
    // pages can arrive after mount, so keep the pin until content actually
    // overflows; after that, loading older pages never yanks the reader.
    if (pinnedSessionIDRef.current !== session?.id || events.length === 0) {
      pinnedSessionIDRef.current = session?.id;
      pinToBottomRef.current = true;
    }
    if (!pinToBottomRef.current) return;
    if (list.scrollHeight - list.clientHeight > 8) {
      list.scrollTop = list.scrollHeight;
      pinToBottomRef.current = false;
    }
  }, [events.length, session?.id]);

  const loadEarlier = () => {
    // Older pages are inserted above the first existing message, so after
    // the response the scroll position must be adjusted to keep that message
    // exactly where the reader left it. The button never moves (new content
    // lands below it), so anchoring it would push the current conversation
    // down and flip the viewport onto the older page.
    const list = listRef.current;
    if (!list) return;
    const anchor = loadMoreRef.current ? list.children[1] : list.children[0];
    if (!anchor) return;
    anchorElementRef.current = anchor;
    anchorOffsetRef.current = anchor.getBoundingClientRect().top - list.getBoundingClientRect().top;
    onLoadMore();
  };

  useLayoutEffect(() => {
    // Wait for the loading flag to clear so the measurement runs against the
    // page that actually landed; while the button is disabled its offset is
    // unchanged and consuming the anchor there would lose it.
    if (anchorElementRef.current === null || loadingMore) return;
    const list = listRef.current;
    const anchor = anchorElementRef.current;
    const target = anchorOffsetRef.current;
    anchorElementRef.current = null;
    anchorOffsetRef.current = null;
    if (!list || !anchor.isConnected) return;
    if (target === null || target === undefined) return;
    const current = anchor.getBoundingClientRect().top - list.getBoundingClientRect().top;
    const delta = current - target;
    if (delta) {
      list.scrollTop += delta;
      // Keep the follow-bottom effect from overriding the anchor on the same
      // render when the remaining content is barely taller than the viewport.
      skipFollowRef.current = true;
    }
  }, [events.length, hasMore, loadingMore]);

  useEffect(() => {
    const list = listRef.current;
    if (!list || pinToBottomRef.current) return;
    if (skipFollowRef.current) {
      skipFollowRef.current = false;
      return;
    }
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 160;
    if (followsBottom) list.scrollTop = list.scrollHeight;
  }, [events.length]);

  const submit = () => {
    if (!ready) return;
    const value = draft.trim();
    if (!value) return;
    onSend(value);
    setDraft("");
    inputRef.current?.focus();
  };

  return (
    <div
      className="agent-view"
      onPointerDown={event => event.stopPropagation()}
      onClick={event => event.stopPropagation()}
    >
      <div ref={listRef} className="agent-events" aria-label={`${displayTitle} conversation`}>
        {hasMore && (
          <button
            ref={loadMoreRef}
            type="button"
            className="agent-load-more"
            onClick={loadEarlier}
            disabled={loadingMore}
          >
            {loadingMore ? "Loading…" : "Load earlier messages"}
          </button>
        )}
        {blocks.length === 0 ? (
          <div className="agent-empty">
            <div className="agent-empty-mark" aria-hidden="true">✦</div>
            <div className="agent-empty-title">What can I help you with?</div>
            <div className="agent-empty-hint">Messages, tool calls and results will appear here.</div>
          </div>
        ) : (
          blocks.map((block, index) => {
            // Token usage is only useful right after an assistant reply;
            // intermediate counts between tool calls are noise.
            if (block.kind === "usage") {
              const previous = blocks[index - 1];
              if (!previous || previous.kind !== "assistant" || !block.event.usage) return null;
            }
            return <AgentBlock key={blockKindKey(block, index)} block={block} />;
          })
        )}
      </div>
      {ready ? (
        <form
          className="agent-input"
          onSubmit={event => {
            event.preventDefault();
            submit();
          }}
        >
          <textarea
            ref={inputRef}
            value={draft}
            onChange={event => setDraft(event.target.value)}
            onKeyDown={event => {
              if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                event.preventDefault();
                submit();
              }
            }}
            placeholder={`Message ${displayTitle}…`}
            aria-label="Message"
            rows={1}
            enterKeyHint="send"
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck="false"
          />
          <button type="submit" className="agent-send" disabled={!draft.trim()} aria-label="Send">
            <SendIcon />
          </button>
        </form>
      ) : (
        <div className="agent-starting">
          Agent is starting — finish first-time setup in Terminal, then send
          messages from here.
        </div>
      )}
    </div>
  );
}

function blockKindKey(block, index) {
  const id = block.call?.id || block.event?.id || block.event?.seq || block.call?.seq;
  return `${block.kind}-${id || index}`;
}

function AgentBlock({ block }) {
  switch (block.kind) {
  case "user":
  case "assistant": {
    const event = block.event;
    if (event.type === "user") {
      return (
        <div className="agent-message user">
          <div className="agent-bubble">
            <MarkdownContent value={event.content || ""} />
          </div>
        </div>
      );
    }
    return (
      <div className="agent-message assistant">
        <MarkdownContent value={event.content || ""} />
      </div>
    );
  }
  case "activity_group":
    return <ActivityGroup block={block} />;
  case "tool_output": {
    const event = block.event;
    return (
      <div className={`agent-tool-card ${event.toolStatus || "success"}`}>
        <div className="agent-tool-head">
          <span className="agent-tool-chevron open" aria-hidden="true"><ChevronRightIcon /></span>
          <span className="agent-tool-name">{displayToolName(event.toolName)}</span>
          <span className="agent-tool-status">{statusText(event.toolStatus)}</span>
        </div>
        <ToolOutputBody event={event} />
      </div>
    );
  }
  case "system_instructions":
    return null;
  case "usage":
    return null;
  case "error":
    return (
      <div className="agent-error">
        <pre className="agent-body">{block.event.error || block.event.content || ""}</pre>
      </div>
    );
  case "attachment":
    return (
      <div className="agent-attachment">
        <pre className="agent-body">{block.event.content || ""}</pre>
      </div>
    );
  case "system":
    return (
      <div className="agent-system">
        {block.event.content || "System"}
        {block.event.durationMs ? ` · ${formatDuration(block.event.durationMs)}` : ""}
      </div>
    );
  default:
    return (
      <details className="agent-unknown">
        <summary>Unknown event</summary>
        <pre className="agent-body">{JSON.stringify(block.event, null, 2)}</pre>
      </details>
    );
  }
}

function ActivityGroup({ block }) {
  const { reasoning, tools, order } = block;
  const [open, setOpen] = useState(false);
  const status = groupStatus(tools);
  let step = 0;
  return (
    <div className={`agent-activity-group ${status}`}>
      <button type="button" className="agent-activity-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="agent-activity-title">{activityTitle(reasoning.length, tools.length)}</span>
        {!open && toolGroupSummary(tools) && <code className="agent-tool-summary">{toolGroupSummary(tools)}</code>}
        <span className="agent-tool-status">{statusText(status)}</span>
      </button>
      {open && (
        <div className="agent-activity-body">
          {order.map((item, index) => {
            if (item.kind === "reasoning") {
              step += 1;
              return (
                <div className="agent-reasoning-item" key={item.event.seq ?? index}>
                  {reasoning.length > 1 && (
                    <div className="agent-reasoning-item-label">Step {step}</div>
                  )}
                  <MarkdownContent value={item.event.content || ""} />
                </div>
              );
            }
            return <ToolCard key={blockKindKey(item.block, index)} block={item.block} defaultOpen />;
          })}
        </div>
      )}
    </div>
  );
}

function ToolCard({ block, defaultOpen = false }) {
  const call = block.call;
  const lastOutput = block.outputs.at(-1);
  const status = lastOutput?.toolStatus || call.toolStatus || (block.outputs.length ? "success" : "running");
  const [open, setOpen] = useState(defaultOpen);
  const summary = toolDisplay(call, status);
  const isWebSearch = call.toolName === "web_search";
  return (
    <div className={`agent-tool-card ${status}`}>
      <button type="button" className="agent-tool-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className={`agent-tool-chevron${open ? " open" : ""}`} aria-hidden="true"><ChevronRightIcon /></span>
        <span className="agent-tool-name">{displayToolName(call.toolName)}</span>
        {summary && <code className="agent-tool-summary">{summary}</code>}
        {!isWebSearch && <span className="agent-tool-status">{statusText(status)}</span>}
      </button>
      {open && (
        <div className="agent-tool-body">
          {call.toolInput !== undefined && (
            <div className="agent-tool-section">
              <div className="agent-tool-label">Input</div>
              <pre className="agent-body">{JSON.stringify(call.toolInput, null, 2)}</pre>
            </div>
          )}
          {block.outputs.map(output => <ToolOutputBody key={output.seq} event={output} />)}
          {call.files?.length > 0 && <FileList files={call.files} />}
          {!block.outputs.length && (
            <div className="agent-tool-label">Waiting for output…</div>
          )}
        </div>
      )}
    </div>
  );
}

function activityTitle(reasoningCount, toolsCount) {
  const parts = [];
  if (reasoningCount > 0) parts.push(`Thinking × ${reasoningCount}`);
  if (toolsCount > 0) parts.push(`Tools × ${toolsCount}`);
  return parts.join(" · ") || "Activity";
}

function toolGroupSummary(items) {
  const first = items[0]?.call;
  if (!first) return "";
  const summary = toolSummary(first);
  if (summary) return summary;
  if (items.length > 1) {
    const second = items[1]?.call;
    if (second) return toolSummary(second);
  }
  return "";
}

function groupStatus(items) {
  const statuses = new Set(items.map(item => {
    const lastOutput = item.outputs.at(-1);
    return lastOutput?.toolStatus || item.call?.toolStatus || (item.outputs.length ? "success" : "running");
  }));
  if (statuses.has("error")) return "error";
  if (statuses.has("interrupted")) return "interrupted";
  if (statuses.has("running")) return "running";
  return "success";
}

function ToolOutputBody({ event }) {
  return (
    <div className="agent-tool-output">
      {event.error && <div className="agent-tool-error">{event.error}</div>}
      {(event.output || "") !== "" && <pre className="agent-body">{event.output}</pre>}
      {event.files?.length > 0 && <FileList files={event.files} />}
    </div>
  );
}

function statusText(status) {
  switch (status) {
  case "error": return "Failed";
  case "interrupted": return "Interrupted";
  case "running": return "Running…";
  default: return "Completed";
  }
}

function displayToolName(name) {
  const names = {
    Bash: "Shell",
    shell: "Shell",
    Edit: "Edit file",
    Read: "Read file",
    Grep: "Search files",
    Glob: "Find files",
    WebSearch: "Web search",
    web_search: "Web search",
    ApplyPatch: "Apply patch",
    apply_patch: "Apply patch",
    Task: "Subagent",
    Write: "Write file",
  };
  return names[name] || name || "Tool";
}

function SendIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M4 20.5 21 12 4 3.5l1.8 6.9 8.5 1.6-8.5 1.6z" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function toolSummary(call) {
  const input = call.toolInput;
  if (!input || typeof input !== "object") return "";
  if (typeof input.command === "string") return input.command;
  if (typeof input.file_path === "string") return input.file_path;
  if (typeof input.path === "string") return input.path;
  if (typeof input.query === "string") return input.query;
  if (typeof input.pattern === "string") return input.pattern;
  if (typeof input.prompt === "string") return input.prompt;
  if (typeof input.url === "string") return input.url;
  if (Array.isArray(input.queries)) return input.queries.join(", ");
  return "";
}

function toolDisplay(call, status) {
  if (call.toolName !== "web_search") return toolSummary(call);
  const input = call.toolInput || {};
  const target = toolSummary(call);
  if (status === "running") return `Searching the web${target ? ` for ${target}` : ""}…`;
  if (status === "success") return `Searched the web for ${target || "results"}`;
  if (status === "error") return `Web search failed${target ? ` · ${target}` : ""}`;
  if (status === "interrupted") return `Web search interrupted${target ? ` · ${target}` : ""}`;
  return target || "Web search";
}

function basename(path) {
  const index = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  return index >= 0 ? path.slice(index + 1) : path;
}

function MarkdownContent({ value }) {
  return (
    <div className="agent-markdown">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{value}</ReactMarkdown>
    </div>
  );
}

function FileList({ files }) {
  return (
    <div className="agent-files">
      {files.map((file, index) => (
        <span className="agent-file" key={`${file}-${index}`}>{basename(file)}</span>
      ))}
    </div>
  );
}

function formatDuration(milliseconds) {
  const seconds = Math.round(milliseconds / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}
