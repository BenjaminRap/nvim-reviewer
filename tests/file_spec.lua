local fx = require("tests.fixture")

local function marks()
  local c = { add = 0, removed = 0, deleted = 0, comments = 0 }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, require("reviewer.render").ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.line_hl_group == "ReviewerAdd" then c.add = c.add + 1 end
    if d.line_hl_group == "ReviewerDelete" then c.deleted = c.deleted + 1 end
    if d.virt_lines and d.priority == 10 then c.removed = c.removed + #d.virt_lines end
    if d.virt_lines and d.priority == 20 then c.comments = c.comments + 1 end
  end
  return c
end

local function open(path)
  local core = require("reviewer.core")
  require("reviewer.review").open_path(core.step, path)
end

describe("reviewed file", function()
  it("highlights added lines and draws removed ones", function()
    fx.review()
    open("src/app.ts")
    local c = marks()
    expect(c.add).equal(3, "added lines")
    expect(c.removed).equal(2, "removed lines")
  end)

  it("is read-only, and :ReviewEdit unlocks it", function()
    expect(vim.bo.modifiable).falsy("locked")
    vim.cmd("ReviewEdit")
    expect(vim.bo.modifiable).truthy("unlocked")
  end)

  it("shows a deleted file in red", function()
    open("src/old.ts")
    expect(vim.api.nvim_buf_get_name(0)).contains("(deleted)")
    expect(marks().deleted).equal(1)
  end)

  it("switches to side by side and back", function()
    vim.cmd("only")
    open("src/app.ts")
    vim.cmd("ReviewSplit")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    expect(#wins).equal(2, "windows")
    expect(vim.wo[wins[1]].diff and vim.wo[wins[2]].diff).truthy("diff mode")
    expect(marks().add).equal(0, "inline overlay off")
    vim.cmd("ReviewSplit")
    expect(#vim.api.nvim_tabpage_list_wins(0)).equal(1, "windows")
    expect(marks().add).equal(3, "inline overlay back")
  end)

  it("moves between changes with ]c", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    fx.press("]c")
    expect(vim.api.nvim_win_get_cursor(0)[1]).equal(2)
    fx.press("]c")
    expect(vim.api.nvim_win_get_cursor(0)[1]).equal(4)
  end)
  it("shows a comment marker, and the comment when the cursor is on its line", function()
    vim.cmd("only")
    open("src/app.ts")
    local core, config, explain = require("reviewer.core"), require("reviewer.config"), require("reviewer.explain")
    local ctx = core.buffers[vim.api.nvim_get_current_buf()]
    local get = explain.get
    explain.get = function() return { comments = { { block = ctx.hunks[1].id, text = "Why this line changed." } } } end
    config.options.comments = "hover"
    require("reviewer.render").draw(vim.api.nvim_get_current_buf())
    expect(marks().comments).equal(0, "no comment boxes")
    local line = ctx.hunks[1].anchor
    expect(ctx.comment_at[line] ~= nil).truthy("marker line")
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    require("reviewer.render").hover(vim.api.nvim_get_current_buf())
    local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_tabpage_list_wins(0))
    expect(#floats).equal(1, "hover float")
    expect(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false))).contains("Why this line changed.")
    require("reviewer.render").close_hover()
    config.options.comments = "inline"
    explain.get = get
  end)

  it("shows the keys of the file in a bar at the bottom", function()
    local config, keybar = require("reviewer.config"), require("reviewer.keybar")
    config.options.key_hints = true
    keybar.update()
    expect(keybar.kind).equal("file")
    local text = table.concat(vim.api.nvim_buf_get_lines(keybar.buf, 0, -1, false), " ")
    expect(text).contains("]c next change")
    expect(vim.api.nvim_win_get_config(keybar.win).focusable).falsy("not focusable")
    expect(require("reviewer.review").main_win() ~= keybar.win).truthy("files never open in the bar")
    config.options.key_hints = false
    keybar.update()
    expect(keybar.win).equal(nil, "closed")
  end)
end)
