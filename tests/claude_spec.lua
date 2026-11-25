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
end)
