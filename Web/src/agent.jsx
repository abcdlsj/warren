import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { groupAgentEvents } from "./agent.js";

export function AgentView({ session, events = [], onSend }) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const [draft, setDraft] = useState("");
  const blocks = groupAgentEvents(events);

  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 140;
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
    <div className="agent-view">
      {session.agentSessionId && (
        <div className="agent-binding" title={session.transcriptPath || session.agentSessionId}>
          Session <code>{session.agentSessionId}</code>
          {session.transcriptPath && <span className="agent-binding-file">{basename(session.transcriptPath)}</span>}
        </div>
      )}
      <div ref={listRef} className="agent-events" aria-label={`${session.title || "Agent"} conversation`}>
        {blocks.length === 0 ? (
          <div className="agent-empty">
            <div className="agent-empty-title">Start a conversation</div>
            <div className="agent-empty-hint">Messages and tool activity will appear here.</div>
          </div>
        ) : (
          blocks.map((block, index) => <AgentBlock key={blockKindKey(block, index)} block={block} />)
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
          autoComplete="off"
          spellCheck="false"
        />
        <button type="submit" disabled={!draft.trim()}>Send</button>
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
    return (
      <div className={`agent-message ${event.type}`}>
        <div className="agent-role">
          {event.type === "user" ? (event.sidechain ? "Subagent prompt" : "You") : (event.sidechain ? "Subagent" : "Assistant")}
        </div>
        <MarkdownContent value={event.content || ""} />
        {(event.model || event.usage || event.stopReason) && (
          <div className="agent-meta">
            {event.model && <span>{event.model}</span>}
            {event.usage && <UsageChip usage={event.usage} />}
            {event.stopReason && <span>Stopped: {event.stopReason}</span>}
          </div>
        )}
      </div>
    );
  }
  case "tool":
    return <ToolBlock block={block} />;
  case "tool_output": {
    const event = block.event;
    return (
      <details className={`agent-tool ${event.toolStatus || "success"}`}>
        <summary>
          <StatusDot status={event.toolStatus || "success"} />
          <span>{event.toolName || "Tool"} output</span>
        </summary>
        <ToolOutputBody event={event} />
      </details>
    );
  }
  case "reasoning":
    return (
      <details className="agent-reasoning">
        <summary>Thinking</summary>
        <MarkdownContent value={block.event.content || ""} />
      </details>
    );
  case "usage":
    return (
      <div className="agent-system">
        {block.event.model && `${block.event.model} · `}
        <UsageChip usage={block.event.usage} />
      </div>
    );
  case "error":
    return (
      <div className="agent-error">
        <div className="agent-role">Error</div>
        <pre className="agent-body">{block.event.error || block.event.content || ""}</pre>
      </div>
    );
  case "attachment":
    return (
      <div className="agent-attachment">
        <div className="agent-role">Attachment</div>
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

function ToolBlock({ block }) {
  const call = block.call;
  const lastOutput = block.outputs.at(-1);
  const status = lastOutput?.toolStatus || (block.outputs.length ? "success" : "");
  const summary = toolSummary(call);
  return (
    <details className={`agent-tool ${status || "running"}`}>
      <summary>
        <StatusDot status={status || "running"} />
        <span className="agent-tool-name">{call.toolName || "Tool"}</span>
        {summary && <code className="agent-tool-summary">{summary}</code>}
        {call.files?.length > 0 && <FileList files={call.files} inline />}
      </summary>
      {call.toolInput !== undefined && (
        <div className="agent-tool-input">
          <div className="agent-tool-label">Input</div>
          <pre className="agent-body">{JSON.stringify(call.toolInput, null, 2)}</pre>
        </div>
      )}
      {block.outputs.map(output => <ToolOutputBody key={output.seq} event={output} />)}
      {!block.outputs.length && (
        <div className="agent-tool-label">Waiting for output…</div>
      )}
    </details>
  );
}

function ToolOutputBody({ event }) {
  return (
    <div className={`agent-tool-output ${event.toolStatus || "success"}`}>
      {event.error && <div className="agent-tool-error">{event.error}</div>}
      {(event.output || "") !== "" && <pre className="agent-body">{event.output}</pre>}
      {event.files?.length > 0 && <FileList files={event.files} />}
    </div>
  );
}

function StatusDot({ status }) {
  return <span className={`agent-status-dot ${status}`} aria-hidden="true" />;
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
  return "";
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

function FileList({ files, inline = false }) {
  return (
    <span className={`agent-files${inline ? " inline" : ""}`}>
      {files.map((file, index) => (
        <span className="agent-file" key={`${file}-${index}`}>{basename(file)}</span>
      ))}
    </span>
  );
}

function formatDuration(milliseconds) {
  const seconds = Math.round(milliseconds / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}
