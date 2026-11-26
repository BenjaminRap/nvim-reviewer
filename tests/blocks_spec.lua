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

  it("finds blocks left without comments, a comment on one of their lines counts", function()
    local config = require("reviewer.config")
    local keep = config.options.claude.gap_lines
    config.options.claude.gap_lines = 2
    local c = ctx(V1) -- B1: 1 added line, B2: 2 added lines (11-12)
    explain.store(c, { summary = "S", changes = "C", comments = { { block = "B1", text = "a" } } })
    expect(explain.gaps(c)).equal({ "B2" }, "B1 is below the threshold, B2 has no comment")
    explain.store(c, { summary = "S", changes = "C", comments = { { block = "B1", line = 12, text = "about x2" } } })
    expect(explain.gaps(c)).equal({}, "a comment pinned on a line of B2 covers it")
    config.options.claude.gap_lines = keep
  end)

  it("sends the blocks left without comments again, once, and keeps the rest", function()
    fx.review()
    local core, config, claude, prepare = require("reviewer.core"), require("reviewer.config"), require("reviewer.claude"), require("reviewer.prepare")
    local keep, real = config.options.claude.gap_lines, claude.run
    config.options.claude.gap_lines = 1
    local prompts = {}
    claude.run = function(prompt, o, cb)
      prompts[#prompts + 1] = { use = o.use, text = prompt }
      if o.use == "overview" then return cb(nil, { summary = "S", files = {}, path = {} }, { cost = 0 }) end
      local files = {}
      if #prompts == 2 then
        -- first round: src/app.ts gets a comment on B1 only
        files = { { path = "src/app.ts", summary = "App", changes = "Changed", comments = { { block = "B1", text = "first" } } } }
      else
        files = { { path = "src/app.ts", summary = "", changes = "", comments = { { block = "B2", text = "second" } } } }
      end
      cb(nil, { files = files }, { cost = 0 })
    end
    local done = false
    prepare.step(core.step, { stages = { comments = true }, paths = { ["src/app.ts"] = true }, force = true, confirmed = true }, function() done = true end)
    vim.wait(1000, function() return done end)
    claude.run, config.options.claude.gap_lines = real, keep
    local comments = {}
    for _, p in ipairs(prompts) do comments[#comments + 1] = p.use end
    expect(#prompts).equal(3, "overview, comments, one round on the gaps")
    expect(prompts[3].text).contains("Blocks B2 have no comment yet")
    local e = explain.get(core.make_ctx(core.step, require("reviewer.git").find_file(core.project, core.step, "src/app.ts")))
    local texts = {}
    for _, c in ipairs(e.comments) do texts[#texts + 1] = c.text end
    table.sort(texts)
    expect(texts).equal({ "first", "second" })
    expect(e.summary).equal("App", "the summary of the first round is kept")
    -- leave the review as it was for the next tests
    local ex = state.explain(core.project)
    ex.steps[core.step.id] = nil
    ex.files[core.step.id .. "|src/app.ts"] = nil
  end)
end)
