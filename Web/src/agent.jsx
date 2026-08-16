import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { groupAgentEvents } from "./agent.js";

export function AgentView({
  session,
  events = [],
  onSend,
  hasMore = false,
  loadingMore = false,
  onLoadMore = () => {},
}) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const [draft, setDraft] = useState("");
  const blocks = groupAgentEvents(events);

  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 160;
    if (followsBottom) list.scrollTop = list.scrollHeight;
  }, [events.length]);

  const submit = () => {
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
      <div ref={listRef} className="agent-events" aria-label={`${session.title || "Agent"} conversation`}>
        {hasMore && (
          <button
            type="button"
            className="agent-load-more"
            onClick={onLoadMore}
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
          placeholder={`Message ${session.title || "agent"}…`}
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
  case "tool":
    return <ToolCard block={block} />;
  case "tool_output": {
    const event = block.event;
    return (
      <div className={`agent-tool-card ${event.toolStatus || "success"}`}>
        <div className="agent-tool-head">
          <ToolIcon name={event.toolName} />
          <span className="agent-tool-name">{displayToolName(event.toolName)}</span>
          <span className="agent-tool-status">{statusText(event.toolStatus)}</span>
        </div>
        <ToolOutputBody event={event} />
      </div>
    );
  }
  case "reasoning":
    return <ReasoningCard content={block.event.content || ""} />;
  case "system_instructions":
    return null;
  case "usage":
    if (!block.event.usage) return null;
    return (
      <div className="agent-usage-foot">
        <UsageChip usage={block.event.usage} />
      </div>
    );
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

function ToolCard({ block }) {
  const call = block.call;
  const lastOutput = block.outputs.at(-1);
  const status = lastOutput?.toolStatus || call.toolStatus || (block.outputs.length ? "success" : "running");
  const [open, setOpen] = useState(false);
  const summary = toolDisplay(call, status);
  const isWebSearch = call.toolName === "web_search";
  return (
    <div className={`agent-tool-card ${status}`}>
      <button type="button" className="agent-tool-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <ToolIcon name={call.toolName} />
        <span className="agent-tool-name">{displayToolName(call.toolName)}</span>
        {summary && <code className="agent-tool-summary">{summary}</code>}
        {!isWebSearch && <span className="agent-tool-status">{statusText(status)}</span>}
        <span className={`agent-tool-chevron${open ? " open" : ""}`} aria-hidden="true">⌄</span>
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

function ReasoningCard({ content }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="agent-reasoning">
      <button type="button" className="agent-reasoning-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className={`agent-reasoning-chevron${open ? " open" : ""}`} aria-hidden="true">▸</span>
        <span className="agent-reasoning-label">Thinking</span>
      </button>
      {open && (
        <div className="agent-reasoning-body">
          <MarkdownContent value={content} />
        </div>
      )}
    </div>
  );
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
    Task: "Subagent",
    Write: "Write file",
  };
  return names[name] || name || "Tool";
}

function ToolIcon({ name }) {
  const key = String(name || "").toLowerCase();
  const path = toolIconPath(key);
  return (
    <span className="agent-tool-icon" aria-hidden="true">
      {path}
    </span>
  );
}

function toolIconPath(key) {
  if (key.includes("bash") || key.includes("shell")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M2 3l6 5-6 5V3zm7 10h5v-1H9v1z" fill="currentColor"/></svg>;
  }
  if (key.includes("edit") || key.includes("write") || key.includes("apply")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M11.3 1.3l3.4 3.4-9 9H2v-3.7l9.3-8.7z" fill="currentColor"/></svg>;
  }
  if (key.includes("read") || key.includes("glob")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M2 3h12v10H2V3zm1 1v8h10V4H3zm2 2h6v1H5V6zm0 2h6v1H5V8zm0 2h4v1H5v-1z" fill="currentColor"/></svg>;
  }
  if (key.includes("grep") || key.includes("search")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M6.5 2a4.5 4.5 0 102.8 8l3.4 3.4 1-1L10.2 9A4.5 4.5 0 006.5 2zm0 1a3.5 3.5 0 110 7 3.5 3.5 0 010-7z" fill="currentColor"/></svg>;
  }
  if (key.includes("web") || key.includes("http")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M8 1a7 7 0 100 14A7 7 0 008 1zm-1 1.1A5.9 5.9 0 003.1 6H6V2.1zM7 2v4h2V2H7zm3 .4V6h2.9A5.9 5.9 0 0010 2.4zM2.2 7h3v2h-3A6 6 0 012.2 7zm4 0v2h3.6V7H6.2zm4.6 0h3a6 6 0 01.2 2h-3V7zM3.1 10h2.9v3.9A5.9 5.9 0 013.1 10zm3.9 3.9V10H9v3.9A6 6 0 017 13.9zM10 10v3.9a5.9 5.9 0 002.9-3.9H10z" fill="currentColor"/></svg>;
  }
  if (key.includes("task")) {
    return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M8 1l1.8 4.6L14.5 7 9.8 8.8 8 13.5 6.2 8.8 1.5 7l4.7-1.4L8 1z" fill="currentColor"/></svg>;
  }
  return <svg viewBox="0 0 16 16" width="12" height="12"><path d="M3 2h10v2H3V2zm0 5h10v2H3V7zm0 5h7v2H3v-2z" fill="currentColor"/></svg>;
}

function SendIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <path d="M1.5 1.8l13 6.2-13 6.2 2.2-6.2L1.5 1.8zm3.6 7.2l-1.2 3.5 7.4-3.5-7.4-3.5 1.2 3.5z" fill="currentColor"/>
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

function UsageChip({ usage }) {
  const parts = [];
  if (usage.inputTokens) parts.push(`${usage.inputTokens} in`);
  if (usage.outputTokens) parts.push(`${usage.outputTokens} out`);
  if (usage.reasoningOutputTokens) parts.push(`${usage.reasoningOutputTokens} reasoning`);
  if (usage.totalTokens) parts.push(`${usage.totalTokens} total`);
  if (!parts.length) return null;
  return <span className="agent-usage-chip">{parts.join(" · ")}</span>;
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
