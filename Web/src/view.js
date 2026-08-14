// React owns all markup. Keep this small pure helper for protocol-adjacent tests
// and any callers that need to escape text before handing it to a non-React sink.
export function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>'"]/g, character => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[character]);
}
