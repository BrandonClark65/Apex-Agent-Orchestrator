import { diffLines, diffRows, diffStats } from "c/aaoPromptDiff";

describe("diffLines", () => {
  it("marks every line unchanged when the texts match", () => {
    const rows = diffLines("a\nb\nc", "a\nb\nc");
    expect(rows.map((r) => r.type)).toEqual([
      "unchanged",
      "unchanged",
      "unchanged"
    ]);
  });

  it("detects an inserted line without disturbing its neighbours", () => {
    const rows = diffLines("a\nc", "a\nb\nc");
    expect(rows).toEqual([
      { type: "unchanged", text: "a" },
      { type: "added", text: "b" },
      { type: "unchanged", text: "c" }
    ]);
  });

  it("detects a removed line", () => {
    const rows = diffLines("a\nb\nc", "a\nc");
    expect(rows).toEqual([
      { type: "unchanged", text: "a" },
      { type: "removed", text: "b" },
      { type: "unchanged", text: "c" }
    ]);
  });

  it("reports a changed line as a removal plus an addition", () => {
    const rows = diffLines("a\nold\nc", "a\nnew\nc");
    expect(rows.filter((r) => r.type === "removed")).toEqual([
      { type: "removed", text: "old" }
    ]);
    expect(rows.filter((r) => r.type === "added")).toEqual([
      { type: "added", text: "new" }
    ]);
  });

  it("treats empty and null input as no lines", () => {
    expect(diffLines("", "")).toEqual([]);
    expect(diffLines(null, undefined)).toEqual([]);
  });

  it("handles a first version being written from nothing", () => {
    const rows = diffLines("", "a\nb");
    expect(rows.map((r) => r.type)).toEqual(["added", "added"]);
  });

  it("normalises CRLF so a line-ending change is not a diff", () => {
    expect(
      diffLines("a\r\nb", "a\nb").every((r) => r.type === "unchanged")
    ).toBe(true);
  });
});

describe("diffStats", () => {
  it("counts additions and removals separately", () => {
    expect(diffStats("a\nb\nc", "a\nx\ny\nc")).toEqual({
      added: 2,
      removed: 1
    });
  });

  it("reports no changes for identical text", () => {
    expect(diffStats("same", "same")).toEqual({ added: 0, removed: 0 });
  });
});

describe("diffRows", () => {
  it("decorates rows with a prefix and css class for rendering", () => {
    const rows = diffRows("a", "b");
    expect(rows[0].prefix).toBe("-");
    expect(rows[0].cssClass).toBe("diff-line diff-removed");
    expect(rows[1].prefix).toBe("+");
    expect(rows[1].cssClass).toBe("diff-line diff-added");
  });

  it("gives every row a unique key", () => {
    const keys = diffRows("a\nb\nc", "a\nx\nc").map((r) => r.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("keeps blank lines occupying a row", () => {
    const rows = diffRows("", "a\n\nb");
    const blank = rows.find((r) => r.text === " ");
    expect(blank).toBeDefined();
  });
});
