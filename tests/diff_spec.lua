local diff = require("reviewer.diff")

describe("diff", function()
  local text = table.concat({
    "diff --git a/x b/x", "--- a/x", "+++ b/x",
    "@@ -2 +2 @@", "-const b = 2", "+const b = 20",
    "@@ -4 +4,2 @@", "-export { a, b, c }", "+const d = 4", "+export { a, b, c, d }",
  }, "\n")

  it("parses hunks", function()
    local h = diff.parse(text)
    expect(#h).equal(2, "hunks")
    expect(h[1].new_start).equal(2)
    expect(h[1].removed).equal({ "const b = 2" })
    expect(h[2].new_count).equal(2)
    expect(h[1].anchor).equal(2)
    expect(h[1].above).equal(true)
  end)

  it("anchors a pure deletion below the line before it", function()
    local h = diff.parse("@@ -3,2 +2,0 @@\n-x\n-y")
    expect(h[1].anchor).equal(2)
    expect(h[1].above).equal(false)
  end)

  it("lists the whole file with added and removed lines", function()
    local lines = { "const a = 1", "const b = 20", "const c = 3", "const d = 4", "export { a, b, c, d }" }
    local l = diff.listing(lines, diff.parse(text))
    expect(l).contains("### B1")
    expect(l).contains("    2 + const b = 20")
    expect(l).contains("- const b = 2    [old 2]")
  end)
end)
