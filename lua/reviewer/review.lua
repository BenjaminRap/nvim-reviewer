-- Opening reviewed files, moving between files and changes, read marks.
local config = require("reviewer.config")
local core = require("reviewer.core")
local git = require("reviewer.git")
local state = require("reviewer.state")
local render = require("reviewer.render")
local explain = require("reviewer.explain")
local ui = require("reviewer.ui")

local M = { last_win = nil }

local function is_panel(win)
  return win == require("reviewer.keybar").win or require("reviewer.browser").is_browser(vim.api.nvim_win_get_buf(win))
end

function M.main_win()
  if M.last_win and vim.api.nvim_win_is_valid(M.last_win) and not is_panel(M.last_win) then return M.last_win end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" and not is_panel(w) then return w end
  end
  vim.cmd("botright vsplit")
  return vim.api.nvim_get_current_win()
end

function M.current_ctx()
  local ctx = core.buffers[vim.api.nvim_get_current_buf()]
  if ctx then return ctx end
  if M.last_win and vim.api.nvim_win_is_valid(M.last_win) then
    return core.buffers[vim.api.nvim_win_get_buf(M.last_win)]
  end
end

local function set_keymaps(buf)
  local keys = require("reviewer.keys")
  local km = keys.opts("file")
  keys.map(buf, "n", km.next_change, function() M.jump_change(1) end, "next change")
  keys.map(buf, "n", km.prev_change, function() M.jump_change(-1) end, "previous change")
  keys.map(buf, "n", km.next_file, function() M.move(1) end, "next file")
  keys.map(buf, "n", km.prev_file, function() M.move(-1) end, "previous file")
  keys.map(buf, "n", km.toggle_read, function() M.toggle_read() end, "toggle read")
  keys.map(buf, "n", km.read_next, function() M.read_next() end, "mark read and open the next unread file")
  keys.map(buf, "n", km.explain, function() M.explain(false) end, "Claude's comments on this file")
  keys.map(buf, "n", km.about, function() M.about() end, "about this file")
  keys.map(buf, { "n", "x" }, km.ask, function() require("reviewer.ask").ask_here() end, "ask Claude")
  keys.map(buf, "n", km.browse, function() require("reviewer.browser").open_here() end, "review browser on this folder")
  keys.map(buf, "n", km.toggle_split, function() require("reviewer.split").toggle() end, "inline changes / side by side")
  keys.map(buf, "n", km.comments_style, function() M.toggle_comments_style() end, "comments as boxes / hover markers")
  keys.map(buf, "n", km.help, function() require("reviewer.keybar").help("file") end, "every key")
  local group = vim.api.nvim_create_augroup("reviewer_hover_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = function() render.hover(buf) end })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "InsertEnter" }, { group = group, buffer = buf, callback = function() render.close_hover() end })
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, buffer = buf, callback = function()
    render.close_hover()
    if vim.api.nvim_get_current_buf() == buf then render.hover(buf) end
  end })
end

function M.attach(buf, ctx)
  if not core.project or not vim.api.nvim_buf_is_valid(buf) then return end
  if core.buffers[buf] then
    core.current = core.buffers[buf]
    render.draw(buf)
    return
  end
  if not ctx then
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or name:match("^reviewer://") then return end
    local step, f = core.locate(name)
    if not step then return end
    ctx = core.make_ctx(step, f)
  end
  if not ctx then return end
  core.buffers[buf] = ctx
  core.current = ctx
  set_keymaps(buf)
  if config.options.readonly then M.lock(buf, true) end
  if vim.bo[buf].modified == false and ctx.dir then
    local dirty = git.run({ "status", "--porcelain", "--", ctx.file.path }, ctx.dir)
    if dirty and dirty ~= "" then ui.notify(ctx.file.path .. " has local changes; the overlay may not line up.", vim.log.levels.WARN) end
  end
  render.draw(buf)
  explain.ensure(ctx)
  core.changed()
end

-- Open a file of a step in the main window, optionally at a line.
-- Lock or unlock a reviewed buffer.
function M.lock(buf, locked)
  vim.bo[buf].modifiable = not locked
  vim.bo[buf].readonly = locked
end

-- :ReviewEdit: allow changes in the current reviewed file (until it is closed).
function M.unlock()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = core.buffers[buf]
  if not ctx then return ui.notify("this buffer is not a reviewed file", vim.log.levels.WARN) end
  if ctx.deleted then return ui.notify("this file is deleted in this step; there is nothing to edit", vim.log.levels.WARN) end
  M.lock(buf, false)
  local where = ctx.dir == ctx.project.root and "your own checkout" or ("the hidden checkout (" .. ctx.dir .. "), on no branch, and are lost when it moves to another review")
  ui.notify(("editing unlocked for %s. Changes go to %s, and the review overlay may no longer line up."):format(ctx.file.path, where), vim.log.levels.WARN)
end

-- Open a file of the review, optionally at a line, in `win` (default: the main window).
function M.open(step, f, line, win)
  local project = core.project
  win = win or M.main_win()
  vim.api.nvim_set_current_win(win)
  M.last_win = win
  if f.status == "D" then
    local name = ("reviewer://%s/%s (deleted)"):format(step.id, f.path)
    local buf = vim.fn.bufnr(name)
    if buf == -1 then
      buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, name)
      local content = git.show(project, step.base_ref, f.path) or ""
      local lines = vim.split(content, "\n", { plain = true })
      if lines[#lines] == "" then lines[#lines] = nil end
      ui.set_lines(buf, lines)
      vim.bo[buf].filetype = vim.filetype.match({ filename = f.path }) or ""
    end
    vim.api.nvim_win_set_buf(win, buf)
    local ctx = core.make_ctx(step, f)
    if ctx then M.attach(buf, ctx) end
  else
    local dir, err = git.step_dir(project, step, true)
    if not dir then return ui.notify(err or "no checkout for this review", vim.log.levels.ERROR) end
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. f.path))
    M.attach(vim.api.nvim_get_current_buf())
  end
  local opened = core.buffers[vim.api.nvim_win_get_buf(win)]
  if opened then require("reviewer.split").follow(opened, win) end
  if line then pcall(vim.api.nvim_win_set_cursor, win, { line, 0 }) ; vim.cmd("normal! zz") end
  local st = state.get(project)
  st.ui.last = st.ui.last or {}
  st.ui.last[step.id] = f.path
  state.save(project)
  core.changed()
end

function M.open_path(step, path, line)
  local f = git.find_file(core.project, step, path)
  if f then return M.open(step, f, line) end
  ui.notify(path .. " is not changed in " .. step.label, vim.log.levels.WARN)
end

local function visible_files(step)
  local b = require("reviewer.browser")
  local hide = b.hide_generated
  if hide == nil then hide = config.options.hide_generated end
  return core.ordered(step, { hide_generated = hide, order = "reading" })
end

function M.move(delta, unread_only)
  local ctx = M.current_ctx()
  local step = ctx and ctx.step or core.step
  local files = visible_files(step)
  if #files == 0 then return end
  local idx = 0
  if ctx then
    for i, f in ipairs(files) do if f.path == ctx.file.path then idx = i end end
  end
  local n = #files
  for k = 1, n do
    local i = ((idx - 1 + delta * k) % n) + 1
    if idx == 0 then i = delta > 0 and k or (n - k + 1) end
    local f = files[i]
    if not unread_only or not core.is_read(f.path, step) then
      -- from a reviewed file, open the next one in the same window
      local here = core.buffers[vim.api.nvim_get_current_buf()] and vim.api.nvim_get_current_win() or nil
      return M.open(step, f, nil, here)
    end
  end
  ui.notify("every file of " .. step.label .. " is read. Time for the quiz: :ReviewQuiz")
end

function M.toggle_read(ctx)
  ctx = ctx or M.current_ctx()
  if not ctx then return ui.notify("this buffer is not a reviewed file", vim.log.levels.WARN) end
  local now = core.is_read(ctx.file.path, ctx.step)
  state.set_read(ctx.project, ctx.step.id, { ctx.file.path }, not now)
  ui.notify((now and "unread: " or "read: ") .. ctx.file.path)
  core.changed()
end

function M.read_next()
  local ctx = M.current_ctx()
  if ctx then state.set_read(ctx.project, ctx.step.id, { ctx.file.path }, true) end
  core.changed()
  M.move(1, true)
end

function M.jump_change(delta)
  local ctx = M.current_ctx()
  if not ctx then return end
  local targets = {}
  for _, h in ipairs(ctx.hunks) do targets[#targets + 1] = h.anchor end
  table.sort(targets)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local pick
  if delta > 0 then
    for _, t in ipairs(targets) do if t > cur then pick = t break end end
    pick = pick or targets[1]
  else
    for i = #targets, 1, -1 do if targets[i] < cur then pick = targets[i] break end end
    pick = pick or targets[#targets]
  end
  if pick then vim.api.nvim_win_set_cursor(0, { math.min(pick, vim.api.nvim_buf_line_count(0)), 0 }) ; vim.cmd("normal! zz") end
end

-- Write Claude's comments on a file; if it already has some, ask before writing them again.
function M.explain_ctx(ctx, force)
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  if force or not explain.get(ctx) then return explain.ensure(ctx, { force = force, manual = true }) end
  vim.ui.select({ "Yes, write them again", "No" }, { prompt = ctx.file.path .. " already has comments. Write them again?" }, function(c)
    if c and c:match("^Yes") then explain.ensure(ctx, { force = true, manual = true }) end
  end)
end

function M.explain(force) M.explain_ctx(M.current_ctx(), force) end

function M.toggle_comments()
  config.options.show_comments = not config.options.show_comments
  render.draw_all()
  ui.notify("Claude's comments " .. (config.options.show_comments and "shown" or "hidden"))
end

function M.toggle_comments_style()
  config.options.comments = config.options.comments == "hover" and "inline" or "hover"
  config.options.show_comments = true
  render.close_hover()
  render.draw_all()
  render.hover(vim.api.nvim_get_current_buf())
  ui.notify("Claude's comments: " .. (config.options.comments == "hover" and "marker, shown when the cursor is on its line" or "boxes above the code"))
end

-- About the current file: summary, what changed, commits.
function M.about()
  local ctx = M.current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local e = explain.get(ctx)
  local lines = { "# " .. ctx.file.path, "", ("%s · %s · +%d −%d"):format(ctx.step.label, explain.STATUS[ctx.file.status] or ctx.file.status, ctx.file.add, ctx.file.del), "" }
  if e then
    vim.list_extend(lines, { "## What this file is", "" }); vim.list_extend(lines, ui.wrap(e.summary, config.options.float.text_width or 96))
    vim.list_extend(lines, { "", "## What changed here", "" }); vim.list_extend(lines, ui.wrap(e.changes, config.options.float.text_width or 96))
    lines[#lines + 1] = ""
  else
    lines[#lines + 1] = explain.status[explain.key(ctx)] == "pending" and "_Claude is writing the comments…_" or "_No comments yet. Run :ReviewExplain._"
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "## Commits touching it"
  lines[#lines + 1] = ""
  for _, c in ipairs(git.commits(ctx.project, ctx.step, ctx.file.path)) do
    lines[#lines + 1] = ("- `%s` %s (%s, %s)"):format(c.hash, c.subject, c.author, c.date)
  end
  ui.show("About this file", lines, { width = (config.options.float.text_width or 96) + 8 })
end

return M
