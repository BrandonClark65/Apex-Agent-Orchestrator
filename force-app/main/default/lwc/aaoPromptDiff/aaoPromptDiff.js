/**
 * Line-level diff between two prompt versions.
 *
 * Written by hand rather than pulled from a library: LWC runs under a strict CSP that blocks
 * external scripts, and the project carries no diff dependency for runtime code.
 *
 * Uses the standard longest-common-subsequence table. Prompts are a few hundred lines at most,
 * so the O(n*m) table is comfortably cheap; the guard below covers pathological inputs.
 */

const MAX_LINES = 2000;

/**
 * Diffs two blocks of text line by line.
 *
 * @param {string} before text of the older version
 * @param {string} after text of the newer version
 * @returns {Array<{type: 'added'|'removed'|'unchanged', text: string}>} ordered diff rows
 */
export function diffLines(before, after) {
  const a = splitLines(before);
  const b = splitLines(after);

  // Too big to diff meaningfully — report wholesale replacement rather than hang the browser.
  if (a.length > MAX_LINES || b.length > MAX_LINES) {
    return [
      ...a.map((text) => ({ type: "removed", text })),
      ...b.map((text) => ({ type: "added", text }))
    ];
  }

  const lcs = buildLcsTable(a, b);
  const rows = [];
  let i = 0;
  let j = 0;

  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      rows.push({ type: "unchanged", text: a[i] });
      i += 1;
      j += 1;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      rows.push({ type: "removed", text: a[i] });
      i += 1;
    } else {
      rows.push({ type: "added", text: b[j] });
      j += 1;
    }
  }
  while (i < a.length) {
    rows.push({ type: "removed", text: a[i] });
    i += 1;
  }
  while (j < b.length) {
    rows.push({ type: "added", text: b[j] });
    j += 1;
  }
  return rows;
}

/**
 * Diffs two texts and decorates each row for direct rendering in a template.
 *
 * @param {string} before text of the older version
 * @param {string} after text of the newer version
 * @returns {Array<{key: string, prefix: string, cssClass: string, text: string}>} renderable rows
 */
export function diffRows(before, after) {
  return diffLines(before, after).map((row, index) => ({
    key: `${index}-${row.type}`,
    prefix: row.type === "added" ? "+" : row.type === "removed" ? "-" : " ",
    cssClass: `diff-line diff-${row.type}`,
    // A blank line still needs to occupy a row, hence the non-breaking space.
    text: row.text === "" ? " " : row.text
  }));
}

/**
 * Counts how many lines the diff adds and removes.
 *
 * @param {string} before text of the older version
 * @param {string} after text of the newer version
 * @returns {{added: number, removed: number}} change counts
 */
export function diffStats(before, after) {
  let added = 0;
  let removed = 0;
  for (const row of diffLines(before, after)) {
    if (row.type === "added") {
      added += 1;
    } else if (row.type === "removed") {
      removed += 1;
    }
  }
  return { added, removed };
}

function splitLines(text) {
  if (!text) {
    return [];
  }
  return String(text).replace(/\r\n/g, "\n").split("\n");
}

// lcs[i][j] = length of the longest common subsequence of a[i..] and b[j..].
function buildLcsTable(a, b) {
  const table = Array.from({ length: a.length + 1 }, () =>
    new Array(b.length + 1).fill(0)
  );
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      table[i][j] =
        a[i] === b[j]
          ? table[i + 1][j + 1] + 1
          : Math.max(table[i + 1][j], table[i][j + 1]);
    }
  }
  return table;
}
