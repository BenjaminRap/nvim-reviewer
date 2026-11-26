local fx = require("tests.fixture")

local function read(path) return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end
local function write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

describe("saved state", function()
  it("writes each review in its own folder, and the shared settings on top", function()
    fx.review()
    local core, state = require("reviewer.core"), require("reviewer.state")
    state.set_read(core.project, core.step.id, { "src/new.ts" }, true)
    state.flush_all()
    local dir = core.project.data_dir
    local review = read(dir .. "/reviews/main..feature/state.json")
    expect(review.id).equal("main..feature")
    expect(review.read["src/new.ts"] ~= nil).truthy("read mark in the review's folder")
    local top = read(dir .. "/state.json")
    expect(top.read == nil).truthy("no review data on top")
    expect(top.ui.last).equal({ base = "main", head = "feature" })
  end)

  -- A separate project in a temporary folder, loaded as after a restart.
  local function project()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return { name = "p" .. vim.fn.fnamemodify(dir, ":t"), data_dir = dir }
  end

  it("moves data saved by an older version into review folders", function()
    local state = require("reviewer.state")
    local p = project()
    write(p.data_dir .. "/state.json", { version = 1, read = { ["a..b"] = { x = "t" } }, notes = {}, attempts = {}, asks = {},
      ui = { last = { base = "a", head = "b", ["a..b"] = "x" }, browser_view = "reading" } })
    write(p.data_dir .. "/explain.json", { version = 1, files = { ["a..b|x"] = { hash = "h" } }, steps = { ["a..b"] = { summary = "S" } } })
    state._reset()
    expect(state.get(p).read["a..b"].x).equal("t", "loaded from the old file")
    expect(state.explain(p).steps["a..b"].summary).equal("S")
    state.flush_all()
    local r = read(p.data_dir .. "/reviews/a..b/state.json")
    expect(r.read.x).equal("t")
    expect(r.last_file).equal("x")
    expect(read(p.data_dir .. "/reviews/a..b/explain.json").files.x.hash).equal("h")
    local top = read(p.data_dir .. "/state.json")
    expect(top.read == nil).truthy("old data moved out")
    expect(top.ui).equal({ last = { base = "a", head = "b" }, browser_view = "reading" })
    expect(read(p.data_dir .. "/explain.json").files == nil).truthy()
    state._reset()
    expect(state.get(p).read["a..b"].x).equal("t", "reloaded from the review folder")
    expect(state.get(p).ui.last["a..b"]).equal("x")
  end)

  it("never overwrites a review another Neovim saved, and keeps its shared settings", function()
    local state = require("reviewer.state")
    local p = project()
    write(p.data_dir .. "/state.json", { version = 1, ui = { browser_view = "folders" } })
    write(p.data_dir .. "/reviews/a..b/state.json", { id = "a..b", read = { x = "1" } })
    write(p.data_dir .. "/reviews/c..d/state.json", { id = "c..d", read = { y = "1" } })
    state._reset()
    state.get(p) -- this Neovim loads both reviews
    -- meanwhile another Neovim, on review c..d, saves a new read mark and the reading view
    write(p.data_dir .. "/reviews/c..d/state.json", { id = "c..d", read = { y = "1", z = "2" } })
    write(p.data_dir .. "/state.json", { version = 1, ui = { browser_view = "reading" } })
    -- this one changes review a..b and the last review
    state.set_read(p, "a..b", { "w" }, true)
    state.get(p).ui.last = { base = "a", head = "b" }
    state.flush_all()
    expect(read(p.data_dir .. "/reviews/c..d/state.json").read.z).equal("2", "the other review is untouched")
    expect(read(p.data_dir .. "/reviews/a..b/state.json").read.w ~= nil).truthy("this review saved")
    local top = read(p.data_dir .. "/state.json")
    expect(top.ui.browser_view).equal("reading", "the other Neovim's setting kept")
    expect(top.ui.last).equal({ base = "a", head = "b" }, "this Neovim's change saved")
  end)

  it("writes a review emptied here, so deleted data does not come back", function()
    local state = require("reviewer.state")
    local p = project()
    write(p.data_dir .. "/reviews/a..b/state.json", { id = "a..b", notes = { { id = "n1", text = "t" } } })
    state._reset()
    state.get(p).notes["a..b"] = nil
    state.flush_all()
    state._reset()
    expect(state.get(p).notes["a..b"] == nil).truthy("the note stays deleted")
  end)

  it("compares data whatever the order of its keys", function()
    local state = require("reviewer.state")
    expect(state._canon({ b = 1, a = { d = 2, c = 3 } })).equal(state._canon({ a = { c = 3, d = 2 }, b = 1 }))
  end)
end)
