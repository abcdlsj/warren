import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export function AgentView({ session, events = [], onSend }) {
  const listRef = useRef(null);
  const inputRef = useRef(null);
  const [draft, setDraft] = useState("");

  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const followsBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
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
      <div ref={listRef} className="agent-events" aria-label={`${session.title || "Agent"} transcript`}>
        {events.length === 0 ? (
          <div className="agent-empty">Waiting for agent events…</div>
        ) : (
          events.map(event => <AgentEventCard key={event.seq} event={event} />)
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
          placeholder={`Send a message to ${session.title || "agent"}…`}
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

function AgentEventCard({ event }) {
  switch (event.type) {
  case "user":
  case "assistant":
    return (
      <div className={`agent-message ${event.type}`}>
        <div className="agent-role">
          {event.type === "user" ? (event.sidechain ? "Subagent prompt" : "You") : (event.sidechain ? "Subagent" : "Assistant")}
          {event.model && <span className="agent-model">{event.model}</span>}
        </div>
        <MarkdownContent value={event.content || ""} />
        {event.stopReason && <div className="agent-stop-reason">Stopped: {event.stopReason}</div>}
        {event.usage && <UsageChip usage={event.usage} />}
      </div>
    );
  case "reasoning":
    return (
      <details className="agent-reasoning">
        <summary>Thinking</summary>
        <MarkdownContent value={event.content || ""} />
      </details>
    );
  case "tool_call":
    return (
      <div className="agent-tool-call">
        <div className="agent-tool-name">{event.toolName || "Tool"}</div>
        {event.toolInput !== undefined && (
          <pre className="agent-body">{JSON.stringify(event.toolInput, null, 2)}</pre>
        )}
        {event.files?.length > 0 && <FileList files={event.files} />}
      </div>
    );
  case "tool_output":
    return (
      <div className={`agent-tool-output ${event.toolStatus || "success"}`}>
        <details>
          <summary>
            {event.toolName ? `${event.toolName} output` : "Tool output"}
            {event.toolStatus === "error" && " — failed"}
            {event.toolStatus === "interrupted" && " — interrupted"}
          </summary>
          {event.error && <div className="agent-tool-error">{event.error}</div>}
          <pre className="agent-body">{event.output || ""}</pre>
          {event.files?.length > 0 && <FileList files={event.files} />}
        </details>
      </div>
    );
  case "usage":
    return (
      <div className="agent-usage">
        {event.model && <span className="agent-model">{event.model}</span>}
        <UsageChip usage={event.usage} />
      </div>
    );
  case "error":
    return (
      <div className="agent-error">
        <div className="agent-role">Error</div>
        <pre className="agent-body">{event.error || event.content || ""}</pre>
      </div>
    );
  case "attachment":
    return (
      <div className="agent-attachment">
        <div className="agent-role">Attachment</div>
        <pre className="agent-body">{event.content || ""}</pre>
      </div>
    );
  case "system":
    return (
      <div className="agent-system">
        {event.content || ""}
        {event.durationMs ? ` · ${formatDuration(event.durationMs)}` : ""}
      </div>
    );
  default:
    return (
      <details className="agent-unknown">
        <summary>Unknown event</summary>
        <pre className="agent-body">{JSON.stringify(event, null, 2)}</pre>
      </details>
    );
  }
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
        <span className="agent-file" key={`${file}-${index}`}>{file}</span>
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
