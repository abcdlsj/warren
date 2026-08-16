export const agentEventLimit = 2000;

/**
 * Merges agent event batches by sequence number. Transcripts are append-only,
 * but a replayed history can overlap a live batch after a reconnect, so the
 * sequence is the stable identity.
 */
export function mergeAgentEvents(existing = [], incoming = []) {
  const bySequence = new Map();
  for (const event of existing || []) {
    if (event && Number.isFinite(event.seq)) bySequence.set(event.seq, event);
  }
  for (const event of incoming || []) {
    if (event && Number.isFinite(event.seq)) bySequence.set(event.seq, event);
  }
  return [...bySequence.values()]
    .sort((left, right) => left.seq - right.seq)
    .slice(-agentEventLimit);
}

/**
 * Groups a flat transcript into renderable blocks. A tool_call and its
 * matching tool_output(s) become one tool block so the UI can show the call
 * and its result as a single compact step instead of two separate cards.
 * Adjacent reasoning blocks and adjacent tool blocks are then collapsed into
 * groups so a busy turn reads as a conversation first: one folded "Thinking"
 * strip and one folded tools strip instead of a wall of cards.
 */
export function groupAgentEvents(events = []) {
  const blocks = [];
  const pending = new Map();
  for (const event of events) {
    if (event.type === "tool_call") {
      const block = { kind: "tool", call: event, outputs: [] };
      blocks.push(block);
      if (event.callId) pending.set(event.callId, block);
    } else if (event.type === "tool_output") {
      const block = event.callId ? pending.get(event.callId) : null;
      if (block) {
        block.outputs.push(event);
      } else {
        blocks.push({ kind: "tool_output", event });
      }
    } else {
      blocks.push({ kind: event.type, event });
    }
  }
  return collapseAncillaryBlocks(blocks);
}

function collapseAncillaryBlocks(blocks) {
  const collapsed = [];
  const push = block => {
    const last = collapsed[collapsed.length - 1];
    if (block.kind === "reasoning" && last?.kind === "reasoning_group") {
      last.events.push(block.event);
      return;
    }
    if (block.kind === "tool" && last?.kind === "tool_group") {
      last.items.push(block);
      return;
    }
    if (block.kind === "reasoning") {
      collapsed.push({ kind: "reasoning_group", events: [block.event] });
      return;
    }
    if (block.kind === "tool") {
      collapsed.push({ kind: "tool_group", items: [block] });
      return;
    }
    collapsed.push(block);
  };
  for (const block of blocks) push(block);
  return collapsed;
}
