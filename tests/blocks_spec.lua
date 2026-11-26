local fx = require("tests.fixture")

-- A file whose diff changes between two versions of a branch.
local V1 = "@@ -1,1 +1,1 @@\n-old a\n+new a\n@@ -10,0 +11,2 @@\n+x1\n+x2"
local V2 = "@@ -1,1 +1,1 @@\n-old a\n+new a\n@@ -13,0 +14,2 @@\n+x1\n+x2" -- B2 moved 3 lines down
local V3 = "@@ -1,1 +1,1 @@\n-old a\n+newer a\n@@ -13,0 +14,2 @@\n+x1\n+x2" -- B1 changed

describe("comments per block", function()
  local diff, explain, state = require("reviewer.diff"), require("reviewer.explain"), require("reviewer.state")
  local p = { name = "blocks", data_dir = vim.fn.tempname() }
  local function ctx(text)
    return { project = p, step = { id = "a..b" }, file = { path = "f.ts" }, hash = vim.fn.sha256(text), hunks = diff.parse(text) }
  end

  it("keeps the comments of blocks that only moved, without calling Claude", function()
    local real = require("reviewer.claude").run
    local calls = 0
    require("reviewer.claude").run = function() calls = calls + 1 end
    explain.store(ctx(V1), { summary = "S", changes = "C", comments = {
      { block = "B1", text = "about a" },
      { block = "b2", line = 12, text = "about x2" },
    } })
    local e = explain.get(ctx(V2))
    require("reviewer.claude").run = real
    expect(e ~= nil).truthy("comments still shown")
    expect(calls).equal(0)
    expect(e.summary).equal("S")
    local x2
    for _, c in ipairs(e.comments) do if c.text == "about x2" then x2 = c end end
    expect(x2.line).equal(15, "moved with its block")
    expect(x2.block).equal("B2")
  end)

  it("asks only for changed blocks, and keeps the others", function()
    local c3 = ctx(V3)
    local r = explain.reusable(c3)
    expect(r.todo).equal({ "B1" })
    expect(#r.kept).equal(1, "the comment of B2")
    explain.store(c3, { summary = "S3", changes = "C3", comments = {
      { block = "B1", text = "about the new a" },
      { block = "B2", text = "Claude commented B2 again" },
    } }, r)
    local e = explain.get(c3)
    local texts = {}
    for _, c in ipairs(e.comments) do texts[#texts + 1] = c.text end
    table.sort(texts)
    expect(texts).equal({ "about the new a", "about x2" }, "B2 keeps its comment, Claude's extra one is dropped")
  end)

  it("adds fingerprints to comments saved before they existed", function()
    local c1 = ctx(V1)
    state.explain(p).files[explain.key(c1)] = { hash = c1.hash, summary = "old", changes = "", comments = { { block = "B2", line = 11, text = "old one" } } }
    explain.get(c1)
    local e = explain.get(ctx(V2))
    expect(e ~= nil).truthy("reused after the diff moved")
    expect(e.comments[1].line).equal(14)
  end)

  it("tells Claude which blocks to comment", function()
    fx.review()
    local core, git = require("reviewer.core"), require("reviewer.git")
    local c = core.make_ctx(core.step, git.find_file(core.project, core.step, "src/app.ts"))
    expect(#c.hunks >= 2).truthy("two blocks")
    c.reuse = { todo = { "B2" }, kept = {} }
    expect(explain.file_section(c)).contains("Only blocks B2 are new or changed")
    c.reuse = nil
    expect(explain.file_section(c):find("Only blocks", 1, true) == nil).truthy("whole file commented otherwise")
  end)
end)
