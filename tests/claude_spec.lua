local fx = require("tests.fixture")

describe("claude", function()
  local claude = require("reviewer.claude")
  local real = claude.run

  it("reads JSON from a fenced reply", function()
    expect(claude.extract_json("Here:\n```json\n{\"a\": 1}\n```")).equal({ a = 1 })
    expect(claude.extract_json("Sure. {\"b\": [1, 2]} Done.")).equal({ b = { 1, 2 } })
  end)

  it("is not called when a file is opened (default)", function()
    local calls = 0
    claude.run = function() calls = calls + 1 end
    fx.review()
    require("reviewer.review").open_path(require("reviewer.core").step, "src/new.ts")
    claude.run = real
    expect(calls).equal(0, "calls")
  end)

  it("saves and shows comments on request", function()
    claude.run = function(_, opts, cb)
      expect(opts.use).equal("comments")
      cb(nil, { summary = "Summary", changes = "Changes", comments = { { block = "B1", text = "First block" } } }, { cost = 0 })
    end
    local core, explain = require("reviewer.core"), require("reviewer.explain")
    require("reviewer.review").open_path(core.step, "src/app.ts")
    local ctx = core.buffers[vim.api.nvim_get_current_buf()]
    explain.ensure(ctx, { manual = true })
    claude.run = real
    expect(explain.get(ctx).summary).equal("Summary")
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, require("reviewer.render").ns, 0, -1, { details = true })) do
      if m[4].virt_lines and m[4].priority == 20 then found = true end
    end
    expect(found).truthy("comment drawn")
  end)

  it("gives a comment call the cross-file facts of its own files only", function()
    fx.review()
    local core, explain = require("reviewer.core"), require("reviewer.explain")
    local real_overview = explain.overview
    explain.overview = function() return { summary = "S", flows = {}, files = {
      { path = "src/app.ts", role = "the app", links = { "used by src/new.ts:1 (fresh)" } },
      { path = "src/new.ts", role = "new", links = { "calls src/other.ts:9" } },
    } } end
    local ctx = explain.step_context(core.project, core.step, nil, { ["src/app.ts"] = true })
    explain.overview = real_overview
    expect(ctx).contains("used by src/new.ts:1 (fresh)")
    expect(ctx:find("calls src/other.ts:9", 1, true) == nil).truthy("other files' facts left out")
    expect(explain.COMMENT_RULES).contains("Open or search other files only when")
  end)

  it("logs each call's usage in usage.jsonl", function()
    local core = require("reviewer.core")
    local path = core.project.data_dir .. "/usage.jsonl"
    os.remove(path)
    claude.log_usage({ prompt = "abc", opts = { use = "comments", tag = "t" } }, {
      total_cost_usd = 0.12, num_turns = 4, duration_ms = 1000, modelUsage = { ["claude-sonnet"] = {} },
      usage = { input_tokens = 10, output_tokens = 20, cache_read_input_tokens = 30, cache_creation_input_tokens = 40 },
    })
    local lines = vim.fn.readfile(path)
    expect(#lines).equal(1)
    local e = vim.json.decode(lines[1])
    expect(e.use).equal("comments")
    expect(e.turns).equal(4)
    expect(e.cost).equal(0.12)
    expect(e.cache_read_tokens).equal(30)
    expect(e.prompt_chars).equal(3)
  end)
end)
