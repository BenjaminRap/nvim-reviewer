local fx = require("tests.fixture")

-- A reading path as the overview call would store it (src/old.ts left out).
local PATH = {
  { stage = "Flow: new value", why = "How the new value is made.", files = {
    { path = "src/new.ts", why = "Where the value comes from." },
    { path = "src/app.ts", why = "Where it is used." },
  } },
  { stage = "Details", why = "", files = { { path = "src/renamed.ts", why = "Just a rename." } } },
}

describe("reading path", function()
  local explain, real
  local function setup()
    fx.review()
    local core, state = require("reviewer.core"), require("reviewer.state")
    explain = require("reviewer.explain")
    real = explain.overview
    explain.overview = function() return { summary = "", flows = {}, concepts = {}, risks = {}, files = {}, path = PATH } end
    state.set_read(core.project, core.step.id, { "src/app.ts", "src/new.ts", "src/old.ts", "src/renamed.ts" }, false)
    return core
  end
  local function teardown() explain.overview = real end

  it("orders the files along Claude's path, under its stages", function()
    local core = setup()
    local order = {}
    for _, f in ipairs(core.ordered(core.step, { hide_generated = true, order = "reading" })) do order[#order + 1] = f.path end
    expect(table.concat(order, " ")).equal("src/new.ts src/app.ts src/renamed.ts src/old.ts", "left-out files last")
    expect(core.group_of({ path = "src/app.ts" }, core.step).label).equal("1 · Flow: new value")
    teardown()
  end)

  it("marks the next file to read in the browser", function()
    local core = setup()
    vim.cmd("Review browse src")
    require("reviewer.browser").render()
    local line = fx.shown()[fx.cursor_on("next")]
    expect(line).contains("new.ts")
    require("reviewer.state").set_read(core.project, core.step.id, { "src/new.ts" }, true)
    require("reviewer.browser").render()
    expect(fx.shown()[fx.cursor_on("next")]).contains("app.ts")
    teardown()
  end)

  it("goes to the next file of the path, and shows the stage above line 1", function()
    local core = setup()
    local review, render = require("reviewer.review"), require("reviewer.render")
    review.open_path(core.step, "src/new.ts")
    local texts = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, render.ns, 0, 0, { details = true })) do
      for _, l in ipairs(m[4].virt_lines or {}) do
        local text = ""
        for _, c in ipairs(l) do text = text .. c[1] end
        texts[#texts + 1] = text
      end
    end
    local all = table.concat(texts, "\n")
    expect(all).contains("1/2 · Flow: new value · file 1/3")
    expect(all).contains("Where the value") -- cut to the window width
    review.read_next()
    expect(vim.api.nvim_buf_get_name(0)).contains("src/app.ts")
    teardown()
  end)
end)
