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
end)
