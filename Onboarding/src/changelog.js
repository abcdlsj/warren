const LOCAL_CACHE_KEY = "warren.onboarding.changelog.v1";

export function stripMarkdown(value) {
  return value
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[`*_~]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function parseChangelog(markdown) {
  const entries = [];
  let entry = null;
  let section = null;
  let lastItemIndex = -1;

  const finishEntry = () => {
    if (!entry || entry.version.toLowerCase() === "unreleased") return;
    if (entry.sections.some((candidate) => candidate.items.length > 0)) {
      entries.push(entry);
    }
  };

  for (const rawLine of String(markdown).split(/\r?\n/)) {
    const line = rawLine.trimEnd();
    const versionMatch = line.match(
      /^##\s+\[([^\]]+)\](?:\s*-\s*(\d{4}-\d{2}-\d{2}))?\s*$/,
    );
    if (versionMatch) {
      finishEntry();
      entry = {
        version: versionMatch[1].trim(),
        dateISO: versionMatch[2] ?? null,
        sections: [],
      };
      section = null;
      lastItemIndex = -1;
      continue;
    }

    if (!entry || entry.version.toLowerCase() === "unreleased") continue;

    const sectionMatch = line.match(/^###\s+(.+?)\s*$/);
    if (sectionMatch) {
      section = { title: stripMarkdown(sectionMatch[1]), items: [] };
      entry.sections.push(section);
      lastItemIndex = -1;
      continue;
    }

    const bulletMatch = line.match(/^\s*[-*]\s+(.+?)\s*$/);
    if (bulletMatch && section) {
      section.items.push(stripMarkdown(bulletMatch[1]));
      lastItemIndex = section.items.length - 1;
      continue;
    }

    const continuation = line.trim();
    if (
      continuation &&
      section &&
      lastItemIndex >= 0 &&
      !continuation.startsWith("#") &&
      !/^[-*_]{3,}$/.test(continuation)
    ) {
      const text = stripMarkdown(continuation);
      if (text) {
        section.items[lastItemIndex] = `${section.items[lastItemIndex]} ${text}`;
      }
    }
  }

  finishEntry();
  return entries;
}

export function readCachedChangelog() {
  try {
    const cached = JSON.parse(localStorage.getItem(LOCAL_CACHE_KEY) ?? "null");
    if (!cached || !Array.isArray(cached.entries)) return null;
    return cached;
  } catch {
    return null;
  }
}

export function writeCachedChangelog(entries) {
  try {
    localStorage.setItem(
      LOCAL_CACHE_KEY,
      JSON.stringify({ entries, cachedAt: new Date().toISOString() }),
    );
  } catch {
    // Private mode or a disabled storage backend; the network response still works.
  }
}

export async function fetchChangelog(signal) {
  const response = await fetch("/api/changelog", {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) {
    throw new Error(`changelog API ${response.status}`);
  }
  const payload = await response.json();
  if (!Array.isArray(payload.entries)) {
    throw new Error("changelog API returned an invalid payload");
  }
  return payload.entries;
}
