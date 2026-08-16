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
 * Every user message opens a turn. All reasoning steps and tool blocks
 * produced inside that turn fold into one activity strip right after the
 * message, so assistant text fragments never split a busy turn into a wall
 * of cards.
 */
export function groupAgentEvents(events = []) {
  const blocks = [];
  const pending = new Map();
  let turn = null;
  let turnStart = -1;

  const beginTurn = withPlaceholders => {
    turn = { reasoning: [], tools: [], order: [] };
    turnStart = -1;
    if (withPlaceholders) {
      turnStart = blocks.length;
      blocks.push({
        kind: "activity_group",
        reasoning: turn.reasoning,
        tools: turn.tools,
        order: turn.order,
      });
    }
  };

  const endTurn = () => {
    if (!turn) return;
    if (turnStart >= 0) {
      for (let index = turnStart; index < blocks.length;) {
        const block = blocks[index];
        const empty = block.kind === "activity_group"
          && block.reasoning.length === 0
          && block.tools.length === 0;
        if (empty) {
          blocks.splice(index, 1);
        } else {
          index += 1;
        }
      }
    } else if (turn.reasoning.length || turn.tools.length) {
      blocks.push({
        kind: "activity_group",
        reasoning: turn.reasoning,
        tools: turn.tools,
        order: turn.order,
      });
    }
    turn = null;
    turnStart = -1;
  };

  for (const event of events) {
    if (event.type === "user") {
      endTurn();
      blocks.push({ kind: "user", event });
      beginTurn(true);
    } else if (event.type === "reasoning") {
      if (!turn) beginTurn(false);
      turn.reasoning.push(event);
      turn.order.push({ kind: "reasoning", event });
    } else if (event.type === "tool_call") {
      if (!turn) beginTurn(false);
      const block = { kind: "tool", call: event, outputs: [] };
      turn.tools.push(block);
      turn.order.push({ kind: "tool", block });
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
  endTurn();
  return blocks;
}
