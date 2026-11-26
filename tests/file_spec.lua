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

  it("is read-only, and :Review edit unlocks it", function()
    expect(vim.bo.modifiable).falsy("locked")
    vim.cmd("Review edit")
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
    vim.cmd("Review split")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    expect(#wins).equal(2, "windows")
    expect(vim.wo[wins[1]].diff and vim.wo[wins[2]].diff).truthy("diff mode")
    expect(marks().add).equal(0, "inline overlay off")
    vim.cmd("Review split")
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
  it("moves between changes with the arrows too", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    fx.press("<Down>")
    expect(vim.api.nvim_win_get_cursor(0)[1]).equal(2)
    fx.press("<Down>")
    expect(vim.api.nvim_win_get_cursor(0)[1]).equal(4)
    fx.press("<Up>")
    expect(vim.api.nvim_win_get_cursor(0)[1]).equal(2)
  end)
  it("shows a comment marker, and the comment on demand", function()
    vim.cmd("only")
    open("src/app.ts")
    local core, config, explain = require("reviewer.core"), require("reviewer.config"), require("reviewer.explain")
    local ctx = core.buffers[vim.api.nvim_get_current_buf()]
    local get = explain.get
    explain.get = function() return { comments = { { block = ctx.hunks[1].id, text = "Why this line changed." } } } end
    config.options.comments = "marker"
    require("reviewer.render").draw(vim.api.nvim_get_current_buf())
    expect(marks().comments).equal(0, "no comment boxes")
    local line = ctx.hunks[1].anchor
    expect(ctx.comment_at[line] ~= nil).truthy("marker line")
    local signs = vim.api.nvim_buf_get_extmarks(0, require("reviewer.render").ns, { line - 1, 0 }, { line - 1, -1 }, { details = true })
    local has_sign = false
    for _, m in ipairs(signs) do if vim.trim(m[4].sign_text or "") == "✦" then has_sign = true end end
    expect(has_sign).truthy("marker in the sign column")
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    local function nfloats() return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_tabpage_list_wins(0)) end
    expect(nfloats()).equal(0, "never opens on its own")
    require("reviewer.render").hover(vim.api.nvim_get_current_buf())
    local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_tabpage_list_wins(0))
    expect(#floats).equal(1, "hover float")
    expect(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false))).contains("Why this line changed.")
    require("reviewer.render").close_hover()
    config.options.comments = "inline"
    explain.get = get
  end)

  it("shows the comment from its whole block, closes it when the cursor moves, and <leader>rh goes into it", function()
    vim.cmd("only")
    open("src/app.ts")
    local core, config, explain = require("reviewer.core"), require("reviewer.config"), require("reviewer.explain")
    local render = require("reviewer.render")
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local ctx = core.buffers[buf]
    local h = ctx.hunks[1]
    for _, x in ipairs(ctx.hunks) do if x.new_count > h.new_count then h = x end end
    local get = explain.get
    explain.get = function() return { comments = { { block = h.id, text = "About the whole block." } } } end
    local function floats()
      return vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_tabpage_list_wins(0))
    end
    config.options.comments = "marker"
    render.draw(buf)
    local last = h.new_start + h.new_count - 1
    vim.api.nvim_win_set_cursor(0, { last, 0 })
    render.hover(buf)
    expect(#floats()).equal(1, "float on the block's last line")
    render.follow(buf)
    expect(#floats()).equal(1, "CursorMoved without a move keeps it")
    vim.api.nvim_win_set_cursor(0, { h.new_start, 0 })
    render.follow(buf)
    expect(#floats()).equal(0, "closed by a move, even inside the block")
    -- inline mode: the key still shows it, and a second press goes into it
    config.options.comments = "inline"
    render.draw(buf)
    vim.api.nvim_win_set_cursor(0, { h.new_start, 0 })
    render.show_comment(buf)
    expect(#floats()).equal(1, "shown on demand")
    render.show_comment(buf)
    expect(vim.api.nvim_get_current_win() ~= win).truthy("inside the float")
    expect(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false))).contains("About the whole block.")
    fx.press("q")
    expect(vim.api.nvim_get_current_win()).equal(win, "back in the file")
    expect(#floats()).equal(0, "closed by q")
    explain.get = get
    render.draw(buf)
  end)

  it("shows the comment and the note on their own virtual line above the code", function()
    open("src/app.ts")
    local core, config, explain, render = require("reviewer.core"), require("reviewer.config"), require("reviewer.explain"), require("reviewer.render")
    local buf = vim.api.nvim_get_current_buf()
    local ctx = core.buffers[buf]
    -- a block with removed lines above its added lines: the comment goes on top of the red part
    local h
    for _, x in ipairs(ctx.hunks) do if x.above and #x.removed > 0 and x.new_count > 0 then h = x; break end end
    expect(h ~= nil).truthy("a block with removed and added lines")
    local get = explain.get
    explain.get = function() return { comments = { { block = h.id, line = h.anchor, text = "What   this does." } } } end
    config.options.comments = "marker"
    local nlines = vim.api.nvim_buf_line_count(buf)
    render.draw(buf)
    expect(vim.api.nvim_buf_line_count(buf)).equal(nlines, "no real line added")
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, h.anchor - 1, h.anchor - 1, { details = true })) do
      local d = m[4]
      expect(d.virt_text_pos ~= "eol").truthy("nothing at the end of the line")
      for i, l in ipairs(d.virt_lines or {}) do
        for j, c in ipairs(l) do
          if c[2] == "ReviewerCommentTitle" then
            found = true
            expect(d.virt_lines_above).truthy("above the code")
            expect(i).equal(1, "above the removed lines")
            expect(l[j + 1][1]).equal("What this does.")
            expect(#d.virt_lines).equal(1 + #h.removed, "the removed lines below it")
          end
        end
      end
    end
    expect(found).truthy("the comment's virtual line")
    explain.get = get
    render.draw(buf)
  end)

  it("gives a pinned comment the lines up to the next pinned one of its block", function()
    open("src/app.ts")
    local core, explain, render = require("reviewer.core"), require("reviewer.explain"), require("reviewer.render")
    local buf = vim.api.nvim_get_current_buf()
    local ctx = core.buffers[buf]
    local h = ctx.hunks[1]
    for _, x in ipairs(ctx.hunks) do if x.new_count > h.new_count then h = x end end
    expect(h.new_count >= 2).truthy("a block of two lines or more")
    local last = h.new_start + h.new_count - 1
    local get = explain.get
    explain.get = function() return { comments = {
      { block = h.id, line = h.new_start, text = "First section." },
      { block = h.id, line = last, text = "Last section." },
    } } end
    render.draw(buf)
    expect(render.comment_spot(ctx, h.new_start).texts[1]).equal("First section.")
    if last - 1 > h.new_start then
      expect(render.comment_spot(ctx, last - 1).texts[1]).equal("First section.", "up to the next pinned line")
    end
    expect(render.comment_spot(ctx, last).texts[1]).equal("Last section.")
    explain.get = get
    render.draw(buf)
  end)

  it("puts the - of removed lines in the sign column, with the +", function()
    -- signcolumn=auto: the sign column appears only once the + signs exist,
    -- so the first draw must not measure the gutter before the screen is redrawn
    vim.cmd("only")
    vim.cmd("enew")
    vim.o.number, vim.o.relativenumber, vim.o.signcolumn = true, true, "auto"
    open("src/app.ts")
    local render = require("reviewer.render")
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("redraw")
    local textoff = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
      local d = m[4]
      if d.virt_lines and d.priority == 10 then
        found = true
        expect(d.virt_lines_leftcol).truthy("drawn from the left edge")
        -- the last one is a removed line (comments and notes come before them)
        local first = d.virt_lines[#d.virt_lines]
        expect(vim.trim(first[1][1])).equal("-", "the sign first")
        local w = 0
        for i = 1, #first - 1 do
          if first[i][2] == "ReviewerDelete" or first[i][2] == "ReviewerDeleteText" then break end
          w = w + vim.fn.strdisplaywidth(first[i][1])
        end
        expect(w).equal(textoff, "the text starts where the code does")
      end
    end
    expect(found).truthy("removed lines drawn")
  end)

  it("mixes green and red into the background with colors = vivid", function()
    local config, render = require("reviewer.config"), require("reviewer.render")
    local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    vim.o.background = "dark"
    vim.api.nvim_set_hl(0, "Normal", { bg = 0x1a1b26 })
    config.options.colors = "vivid"
    render.setup_highlights()
    local function bg(n) return string.format("#%06x", vim.api.nvim_get_hl(0, { name = n }).bg) end
    expect(bg("ReviewerAdd")).equal("#274334")
    expect(bg("ReviewerDelete")).equal("#4b272e")
    config.options.colors = "colorscheme"
    vim.api.nvim_set_hl(0, "Normal", normal)
  end)

  it("shows the keys of the file in a bar at the bottom", function()
    local config, keybar = require("reviewer.config"), require("reviewer.keybar")
    config.options.key_hints = true
    keybar.update()
    expect(keybar.kind).equal("file")
    local text = table.concat(vim.api.nvim_buf_get_lines(keybar.buf, 0, -1, false), " ")
    expect(text).contains("Change: ↓/↑")
    expect(text).contains("File: →/←")
    expect(#vim.api.nvim_buf_get_lines(keybar.buf, 0, -1, false)).equal(1, "one line")
    expect(vim.api.nvim_win_get_config(keybar.win).focusable).falsy("not focusable")
    expect(require("reviewer.review").main_win() ~= keybar.win).truthy("files never open in the bar")
    -- key_bar hides keys you already know and adds others
    config.options.key_bar = { hide = { file = { "prev_change", "help" } }, show = { file = { "about" } } }
    local columns = vim.o.columns
    vim.o.columns = 200 -- room for the added key
    keybar.update()
    text = table.concat(vim.api.nvim_buf_get_lines(keybar.buf, 0, -1, false), " ")
    expect(text:find("Change:", 1, true)).equal(nil, "a pair is hidden by either name")
    expect(text:find("Keybindings:", 1, true)).equal(nil, "help hidden")
    expect(text).contains("About the file:")
    config.options.key_bar = { hide = {}, show = {} }
    vim.o.columns = columns
    config.options.key_hints = false
    keybar.update()
    expect(keybar.win).equal(nil, "closed")
  end)
end)
