import test from "node:test";
import assert from "node:assert/strict";

import { parseChangelog } from "../src/changelog.js";

test("parseChangelog skips unreleased notes and preserves wrapped bullets", () => {
  const entries = parseChangelog(`# Changelog

## [Unreleased]

- Draft notes stay out of the public list.

## [1.2.0] - 2026-08-20

### Fixed

- Keep the first line
  and append the wrapped line.

### Added

- Link to [the release](https://example.com/release).
`);

  assert.deepEqual(entries, [
    {
      version: "1.2.0",
      dateISO: "2026-08-20",
      sections: [
        {
          title: "Fixed",
          items: ["Keep the first line and append the wrapped line."],
        },
        { title: "Added", items: ["Link to the release."] },
      ],
    },
  ]);
});
