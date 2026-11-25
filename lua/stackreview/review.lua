-- Opening reviewed files, moving between files and changes, read marks.
local config = require("stackreview.config")
local core = require("stackreview.core")
local git = require("stackreview.git")
local state = require("stackreview.state")
local render = require("stackreview.render")
local explain = require("stackreview.explain")
local ui = require("stackreview.ui")

local M = { last_win = nil }

local function is_panel(win)
  local panel = require("stackreview.panel")
  return panel.win ~= nil and win == panel.win
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
  local km = config.options.keymaps or {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "stackreview: " .. desc }) end
  end
  map(km.next_change, function() M.jump_change(1) end, "next change")
  map(km.prev_change, function() M.jump_change(-1) end, "previous change")
  map(km.next_file, function() M.move(1) end, "next file")
  map(km.prev_file, function() M.move(-1) end, "previous file")
  map(km.toggle_read, function() M.toggle_read() end, "toggle read")
  map(km.read_next, function() M.read_next() end, "mark read and open the next unread file")
  map(km.explain, function() M.explain(false) end, "Claude's comments on this file")
  if km.note and km.note ~= "" then
    vim.keymap.set({ "n", "x" }, km.note, function() require("stackreview.notes").add_here() end, { buffer = buf, desc = "stackreview: add a note" })
  end
  if km.ask and km.ask ~= "" then
    vim.keymap.set({ "n", "x" }, km.ask, function() require("stackreview.ask").ask_here() end, { buffer = buf, desc = "stackreview: ask Claude" })
  end
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
    if name == "" or name:match("^stackreview://") then return end
    local step, f = core.locate(name)
    if not step then return end
    ctx = core.make_ctx(step, f)
  end
  if not ctx then return end
  core.buffers[buf] = ctx
  core.current = ctx
  set_keymaps(buf)
  if vim.bo[buf].modified == false and ctx.dir then
    local dirty = git.run({ "status", "--porcelain", "--", ctx.file.path }, ctx.dir)
    if dirty and dirty ~= "" then ui.notify(ctx.file.path .. " has local changes; the overlay may not line up.", vim.log.levels.WARN) end
  end
  render.draw(buf)
  explain.ensure(ctx)
  core.changed()
end

-- Open a file of a step in the main window, optionally at a line.
function M.open(step, f, line)
  local project = core.project
  local win = M.main_win()
  vim.api.nvim_set_current_win(win)
  M.last_win = win
  if f.status == "D" then
    local name = ("stackreview://step%s/%s (deleted)"):format(step.id, f.path)
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
    if not dir then return ui.notify(err or "no folder for this step", vim.log.levels.ERROR) end
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. f.path))
    M.attach(vim.api.nvim_get_current_buf())
  end
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
  ui.notify(path .. " is not changed in step " .. step.id, vim.log.levels.WARN)
end

local function visible_files(step)
  local panel = require("stackreview.panel")
  return core.ordered(step, { hide_generated = panel.hide_generated, order = panel.order })
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
    if not unread_only or not core.is_read(f.path, step) then return M.open(step, f) end
  end
  ui.notify("every file of step " .. step.id .. " is read. Time for the quiz: :ReviewQuiz " .. step.id)
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

-- About the current file: summary, what changed, commits.
function M.about()
  local ctx = M.current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local e = explain.get(ctx)
  local lines = { "# " .. ctx.file.path, "", ("Step %s · %s · +%d −%d"):format(ctx.step.id, explain.STATUS[ctx.file.status] or ctx.file.status, ctx.file.add, ctx.file.del), "" }
  if e then
    vim.list_extend(lines, { "## What this file is", "" }); vim.list_extend(lines, ui.wrap(e.summary, 90))
    vim.list_extend(lines, { "", "## What changed here", "" }); vim.list_extend(lines, ui.wrap(e.changes, 90))
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
  ui.show("About this file", lines, { width = 100 })
end

return M
