-- The review browser: an oil-like buffer listing the changed files of the review,
-- one folder at a time (or all files in reading order).
--   <CR> enters a folder or opens a file, - goes up, _ goes to the root.
--   Read marks are text: change [ ] to [x] with any edit, then :w saves them.
--   Nothing else is ever written: :w only saves read marks, never touches files.
local config = require("reviewer.config")
local core = require("reviewer.core")
local state = require("reviewer.state")
local git = require("reviewer.git")
local explain = require("reviewer.explain")
local keys = require("reviewer.keys")
local ui = require("reviewer.ui")

local M = {
  bufs = {}, -- buf -> { dir, view, items = { id -> item } }
  view = nil, -- "folders" or "reading" (last used)
  show_unchanged = nil,
  hide_generated = nil,
}
local ns = vim.api.nvim_create_namespace("reviewer_browser")

local function sym(name) return config.options.symbols[name] end
local function opt(name) return (config.options.browser or {})[name] end
local function K(name) return keys.label(keys.opts("browser")[name]) end

local function init_flags()
  if M.view == nil then M.view = opt("view") or "folders" end
  if M.show_unchanged == nil then M.show_unchanged = opt("show_unchanged") or false end
  if M.hide_generated == nil then M.hide_generated = config.options.hide_generated end
end

-- File icon from mini.icons or nvim-web-devicons, if installed.
local function icon(name, is_dir)
  if not opt("icons") then return nil end
  local ok, mi = pcall(require, "mini.icons")
  if ok and type(mi) == "table" and mi.get and _G.MiniIcons then
    local ok2, ic, hl = pcall(mi.get, is_dir and "directory" or "file", name)
    if ok2 and ic then return ic, hl end
  end
  if is_dir then return nil end
  local okd, dev = pcall(require, "nvim-web-devicons")
  if okd and dev.get_icon then
    local ic, hl = dev.get_icon(name, name:match("%.([^.]+)$"), { default = true })
    if ic then return ic, hl end
  end
end

------------------------------------------------------------------------ entries
local function visible(f) return not (M.hide_generated and f.generated) end

-- Entries of one folder: subfolders with changes, then changed files, then
-- (when shown) unchanged files and folders, dimmed.
local function folder_entries(dir)
  local folders, files = {}, {}
  for _, f in ipairs(core.files()) do
    if visible(f) then
      local p = f.path
      local rel = dir == "" and p or (p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2) or nil)
      if rel then
        local first = rel:match("^([^/]+)/")
        if first then
          folders[first] = folders[first] or { kind = "folder", name = first, path = (dir == "" and first or dir .. "/" .. first), paths = {} }
          table.insert(folders[first].paths, p)
        else
          files[#files + 1] = { kind = "file", name = rel, file = f }
        end
      end
    end
  end
  local list = {}
  for _, fo in pairs(folders) do list[#list + 1] = fo end
  table.sort(list, function(a, b) return a.name < b.name end)
  table.sort(files, function(a, b) return a.name < b.name end)
  vim.list_extend(list, files)
  if M.show_unchanged then
    local out = git.run({ "ls-tree", core.step.head_ref .. ":" .. dir }, core.project.root) or ""
    -- names changed in this folder, hidden generated files included
    local changed = {}
    for _, f in ipairs(core.files()) do
      local rel = dir == "" and f.path or (f.path:sub(1, #dir + 1) == dir .. "/" and f.path:sub(#dir + 2) or nil)
      if rel then changed[rel:match("^([^/]+)")] = true end
    end
    local extra = {}
    for _, l in ipairs(vim.split(out, "\n", { trimempty = true })) do
      local typ, name = l:match("^%d+ (%w+) %x+\t(.+)$")
      if typ and not changed[name] then
        extra[#extra + 1] = { kind = typ == "tree" and "plain_dir" or "plain", name = name, path = (dir == "" and name or dir .. "/" .. name) }
      end
    end
    table.sort(extra, function(a, b)
      if (a.kind == "plain_dir") ~= (b.kind == "plain_dir") then return a.kind == "plain_dir" end
      return a.name < b.name
    end)
    vim.list_extend(list, extra)
  end
  return list
end

-- All files in reading order, under group headers.
local function reading_entries()
  local list, groups, order = {}, {}, {}
  for _, f in ipairs(core.ordered(core.step, { hide_generated = M.hide_generated, order = "reading" })) do
    local g = core.group_of(f, core.step)
    if not groups[g.label] then groups[g.label] = { kind = "group", name = g.label, paths = {}, files = {} } ; order[#order + 1] = g.label end
    table.insert(groups[g.label].paths, f.path)
    table.insert(groups[g.label].files, f)
  end
  for _, label in ipairs(order) do
    local g = groups[label]
    list[#list + 1] = g
    for _, f in ipairs(g.files) do list[#list + 1] = { kind = "file", name = f.path, file = f, in_group = true } end
  end
  return list
end

------------------------------------------------------------------------ render
local function read_count(paths)
  local n = 0
  for _, p in ipairs(paths) do if core.is_read(p) then n = n + 1 end end
  return n
end

local function winbar_text(info)
  local read, total = core.reviewable(core.step)
  local where = info.view == "reading" and "reading order" or ((info.dir == "" and "" or info.dir .. "/"))
  local parts = { core.step.label, where ~= "" and where or "/", ("%d/%d read"):format(read, total) }
  local ps = require("reviewer.prepare").status(core.step.id)
  if ps then parts[#parts + 1] = ps end
  local q = require("reviewer.quiz").stats(core.step.id)
  if q.total then parts[#parts + 1] = ("quiz %d/%d"):format(q.answered, q.total) end
  return " " .. table.concat(parts, " · "):gsub("%%", "%%%%") .. " %m"
end

local function set_winbar(buf)
  local info = M.bufs[buf]
  if not info or not core.step then return end
  local text = winbar_text(info)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do vim.wo[w].winbar = text end
end

function M.render_buf(buf, force)
  local info = M.bufs[buf]
  if not info or not vim.api.nvim_buf_is_valid(buf) or not core.step then return end
  if vim.bo[buf].modified and not force then return set_winbar(buf) end
  local entries = info.view == "reading" and reading_entries() or folder_entries(info.dir)
  local cur = core.current and core.current.step.id == core.step.id and core.current.file.path or nil
  -- the next file to read: the first unread one in reading order
  local next_path
  for _, f in ipairs(core.ordered(core.step, { hide_generated = true, order = "reading" })) do
    if not f.binary and not core.is_read(f.path) then next_path = f.path; break end
  end
  local lines, marks, items = {}, {}, {}
  -- keep the cursor on the same entry
  local cursor_key
  local wins = vim.fn.win_findbuf(buf)
  if wins[1] and info.items then
    local l = vim.api.nvim_win_get_cursor(wins[1])[1]
    local id = (vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""):match("^/(%d+) ")
    local it = id and info.items[tonumber(id)]
    cursor_key = it and (it.key or it.name)
  end
  local cursor_line = info.focus and nil
  for i, e in ipairs(entries) do
    local prefix = ("/%d "):format(i)
    local text, hls = "", {}
    local function push(s, hl)
      if hl then hls[#hls + 1] = { #prefix + #text, #prefix + #text + #s, hl } end
      text = text .. s
    end
    if e.kind == "folder" or e.kind == "group" then
      local done = read_count(e.paths)
      local mark = done == 0 and sym("unread") or (done == #e.paths and sym("read") or sym("partly_read"))
      e.mark = mark
      push("[" .. mark .. "] ")
      if e.kind == "folder" then
        local ic, ichl = icon(e.name, true)
        if ic then push(ic .. " ", ichl) end
        push(e.name .. "/", "Directory")
      else
        push(e.name, "ReviewerGroup")
      end
      push(("  %d/%d"):format(done, #e.paths), "ReviewerDim")
      if done == #e.paths then hls[#hls + 1] = { #prefix, #prefix + #text, "ReviewerRead" } end
      e.key = e.kind .. ":" .. (e.path or e.name)
    elseif e.kind == "file" then
      local f = e.file
      local r = core.is_read(f.path)
      push("[" .. (r and sym("read") or sym("unread")) .. "] ")
      push(f.status .. " ", f.status == "A" and "ReviewerAddSign" or f.status == "D" and "ReviewerDeleteSign" or "ReviewerPartial")
      if e.in_group then push("  ") end
      local base = e.in_group and vim.fs.basename(f.path) or e.name
      local ic, ichl = icon(vim.fs.basename(f.path), false)
      if ic then push(ic .. " ", ichl) end
      push(base, r and "ReviewerRead" or nil)
      if e.in_group then
        local d = vim.fs.dirname(f.path)
        if d ~= "." then push("  " .. d, "ReviewerDim") end
      end
      if f.old then push("  ← " .. f.old, "ReviewerDim") end
      if f.binary then push("  bin", "ReviewerDim")
      else
        push("  +" .. f.add, "ReviewerAddSign")
        push(" −" .. f.del, "ReviewerDeleteSign")
      end
      if explain.status[core.step.id .. "|" .. f.path] == "pending" then push("  " .. sym("pending"), "ReviewerDim")
      elseif state.explain(core.project).files[core.step.id .. "|" .. f.path] then push("  " .. sym("comment"), "ReviewerCommentTitle") end
      local nn = require("reviewer.notes").count(f.path)
      if nn > 0 then push("  " .. sym("note") .. (nn > 1 and nn or ""), "ReviewerNote") end
      if f.generated then push("  generated", "ReviewerDim") end
      if f.path == next_path then push("  " .. sym("next") .. " next", "ReviewerAction") end
      if f.path == cur then hls[#hls + 1] = { #prefix, #prefix + #text, "ReviewerCurrent" } end
      e.key = "file:" .. f.path
    else -- unchanged, shown with show_unchanged
      push("    ")
      local ic, ichl = icon(e.name, e.kind == "plain_dir")
      if ic then push(ic .. " ", ichl) end
      push(e.name .. (e.kind == "plain_dir" and "/" or ""), "ReviewerDim")
      e.key = e.kind .. ":" .. e.path
    end
    lines[i] = prefix .. text
    items[i] = e
    marks[i] = { prefix = #prefix, hls = hls }
    if cursor_key and e.key == cursor_key then cursor_line = i end
    if info.focus and e.key == info.focus then cursor_line = i end
  end
  info.focus = nil
  if #lines == 0 then
    lines = { info.view == "reading" and "/0 (no changed file)" or "/0 (no changed file here)" }
    marks = { { prefix = 3, hls = {} } }
  end
  info.items = items
  -- replace the text without undo history, like oil
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = m.prefix, conceal = "" })
    for _, h in ipairs(m.hls) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, h[1], { end_col = math.min(h[2], #lines[i]), hl_group = h[3], priority = h[3] == "ReviewerCurrent" and 5 or 10 })
    end
  end
  if cursor_line then
    for _, w in ipairs(wins) do
      pcall(vim.api.nvim_win_set_cursor, w, { cursor_line, marks[cursor_line] and marks[cursor_line].prefix or 0 })
    end
  end
  set_winbar(buf)
end

function M.render()
  for buf in pairs(M.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then M.render_buf(buf) else M.bufs[buf] = nil end
  end
end

------------------------------------------------------------------------ :w
local function is_unread(mark)
  mark = vim.trim(mark or "")
  return mark == "" or mark == vim.trim(sym("unread"))
end

function M.write(buf)
  local info = M.bufs[buf]
  if not info then return end
  local to_read, to_unread, ignored = {}, {}, 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local id, mark = l:match("^/(%d+) %[(.-)%]")
    local it = id and info.items[tonumber(id)]
    if it and it.kind == "file" then
      local want = not is_unread(mark)
      if want ~= core.is_read(it.file.path) then table.insert(want and to_read or to_unread, it.file.path) end
    elseif it and (it.kind == "folder" or it.kind == "group") then
      if mark ~= it.mark and mark ~= sym("partly_read") then
        vim.list_extend(is_unread(mark) and to_unread or to_read, it.paths)
      end
    elseif vim.trim(l) ~= "" and not l:match("^/%d+ ") then
      ignored = ignored + 1
    end
  end
  if #to_read > 0 then state.set_read(core.project, core.step.id, to_read, true) end
  if #to_unread > 0 then state.set_read(core.project, core.step.id, to_unread, false) end
  vim.bo[buf].modified = false
  local msg = ("%d file(s) marked read, %d unread"):format(#to_read, #to_unread)
  if ignored > 0 then msg = msg .. (" · %d edited line(s) ignored (only [ ] / [x] is saved)"):format(ignored) end
  ui.notify(msg)
  M.render_buf(buf, true)
  core.changed()
end

------------------------------------------------------------------------ actions
local function item_at_cursor(buf)
  local info = M.bufs[buf]
  local l = vim.api.nvim_win_get_cursor(0)[1]
  local id = (vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""):match("^/(%d+) ")
  return info and id and info.items[tonumber(id)], info
end

-- how: nil (this window), "vsplit", "split", "tab", "preview"
local function open_item(buf, how)
  local it, info = item_at_cursor(buf)
  if not it then return end
  if it.kind == "folder" or it.kind == "plain_dir" then
    if how then return end
    return M.open({ dir = it.path, view = "folders" })
  end
  if it.kind == "group" then return end
  local prev_win = vim.api.nvim_get_current_win()
  if how == "vsplit" or how == "preview" then vim.cmd("vsplit")
  elseif how == "split" then vim.cmd("split")
  elseif how == "tab" then vim.cmd("tabnew") end
  local win = vim.api.nvim_get_current_win()
  if it.kind == "file" then
    require("reviewer.review").open(core.step, it.file, nil, win)
  else
    local dir = git.step_dir(core.project, core.step, true)
    if dir then vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. it.path)) end
  end
  if how == "preview" then vim.api.nvim_set_current_win(prev_win) end
  local _ = info
end

local function help_lines()
  local k = keys.opts("browser")
  local rows = {
    { k.open, "enter a folder / open a file (this window)" },
    { k.open_vsplit, "open in a vertical split" }, { k.open_split, "open in a horizontal split" },
    { k.open_tab, "open in a new tab" }, { k.preview, "preview, staying here" },
    { k.parent, "parent folder" }, { k.root, "root of the review" },
    { k.toggle_view, "folders / all files in reading order" },
    { k.toggle_unchanged, "show or hide unchanged files" },
    { k.toggle_generated, "show or hide generated files" },
    { k.refresh, "refresh" },
    { k.explain, "Claude's comments on the file under the cursor" },
    { k.explain_folder, "comment every file of the folder/group under the cursor" },
    { k.about, "about the file under the cursor" },
    { k.prepare, "prepare the review with Claude" }, { k.stop, "stop preparing" },
    { k.overview, "overview of the changes" }, { k.quiz, "quiz" },
    { k.progress, "progress" },
    { k.notes, "every note of the review, in the quickfix list" },
    { k.new_review, "review other branches" }, { k.close, "back to the previous file" }, { k.help, "this help" },
  }
  local out = { "Read marks: change [ ] to [" .. sym("read") .. "] (or back) with any edit, then :w.", "A folder's box marks everything inside it. u undoes until you save.", "" }
  for _, r in ipairs(rows) do
    local l = keys.labels(r[1])
    if vim.trim(l) ~= "" then out[#out + 1] = ("%-12s %s"):format(l, r[2]) end
  end
  return out
end

local function setup_buffer(buf)
  local k = keys.opts("browser")
  local function map(lhs, fn, desc) keys.map(buf, "n", lhs, fn, desc) end
  map(k.open, function() open_item(buf) end, "open")
  map(k.open_vsplit, function() open_item(buf, "vsplit") end, "open in a vertical split")
  map(k.open_split, function() open_item(buf, "split") end, "open in a horizontal split")
  map(k.open_tab, function() open_item(buf, "tab") end, "open in a new tab")
  map(k.preview, function() open_item(buf, "preview") end, "preview")
  map(k.parent, function()
    local info = M.bufs[buf]
    if info.view == "reading" then return M.open({ dir = "", view = "folders" }) end
    if info.dir == "" then return ui.notify("already at the root of the review") end
    local parent = vim.fs.dirname(info.dir)
    M.open({ dir = parent == "." and "" or parent, view = "folders", focus = "folder:" .. info.dir })
  end, "parent folder")
  map(k.root, function() M.open({ dir = "", view = "folders" }) end, "root")
  map(k.toggle_view, function()
    local info = M.bufs[buf]
    M.open({ dir = info.dir, view = info.view == "reading" and "folders" or "reading" })
  end, "folders / reading order")
  map(k.toggle_unchanged, function() M.show_unchanged = not M.show_unchanged ; M.render() end, "show or hide unchanged files")
  map(k.toggle_generated, function() M.hide_generated = not M.hide_generated ; M.render() end, "show or hide generated files")
  map(k.refresh, function() git.clear_cache() ; M.render_buf(buf, true) end, "refresh")
  map(k.explain, function()
    local it = item_at_cursor(buf)
    if it and it.kind == "file" then require("reviewer.review").explain_ctx(core.make_ctx(core.step, it.file), false) end
  end, "Claude's comments on the file")
  map(k.explain_folder, function()
    local it = item_at_cursor(buf)
    local paths = it and ((it.kind == "folder" or it.kind == "group") and it.paths or (it.kind == "file" and { it.file.path }))
    if paths then require("reviewer.prepare").paths(core.step, paths) end
  end, "comment every file of the folder")
  map(k.about, function()
    local it = item_at_cursor(buf)
    if it and it.kind == "file" then open_item(buf) ; require("reviewer.review").about() end
  end, "about the file")
  map(k.prepare, function() require("reviewer.prepare").step(core.step) end, "prepare the review")
  map(k.stop, function() require("reviewer.prepare").command({ "stop" }) end, "stop preparing")
  map(k.overview, function() require("reviewer.prepare").overview_then_show(core.step) end, "overview")
  map(k.quiz, function() M.take_quiz(core.step.id) end, "quiz")
  map(k.progress, function() require("reviewer.progress").open() end, "progress")
  map(k.notes, function() require("reviewer.notes").quickfix() end, "notes in the quickfix list")
  map(k.new_review, function() require("reviewer").pick_review() end, "review other branches")
  map(k.close, function() M.close() end, "back to the previous file")
  map(k.help, function() local h = help_lines() ; ui.show("Review browser", h, { width = 80, height = #h + 2 }) end, "help")

  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function() M.write(buf) end })
  vim.api.nvim_create_autocmd("BufWinEnter", { buffer = buf, callback = function()
    local w = vim.api.nvim_get_current_win()
    vim.wo[w].conceallevel = 3
    vim.wo[w].concealcursor = "nvic"
    vim.wo[w].wrap = false
    vim.wo[w].cursorline = true
    set_winbar(buf)
  end })
  vim.api.nvim_create_autocmd("BufWinLeave", { buffer = buf, callback = function()
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      pcall(vim.api.nvim_win_call, w, function() vim.cmd("setlocal winbar< conceallevel< concealcursor<") end)
    end
  end })
  -- keep the cursor after the hidden id, like oil
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function()
    local c = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local p = line:match("^/%d+ ")
    if p and c[2] < #p then pcall(vim.api.nvim_win_set_cursor, 0, { c[1], #p }) end
  end })
end

------------------------------------------------------------------------ open
local function buffer_for(view, dir)
  local name = ("reviewer://%s/%s/%s"):format(core.project.name, core.step.id, view == "reading" and "~reading" or (dir == "" and "" or dir .. "/"))
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not M.bufs[buf] then
    if buf == -1 then
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, name)
    end
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "reviewer"
    M.bufs[buf] = { dir = dir, view = view, items = {} }
    setup_buffer(buf)
  end
  return buf
end

-- Open the browser in the current window.
-- opts: { dir = "src/x", view = "folders"|"reading", focus = "file:path"|"folder:path" }
function M.open(opts)
  if not core.step then return end
  init_flags()
  opts = opts or {}
  local view = opts.view or M.view
  M.view = view
  local dir = view ~= "folders" and "" or (opts.dir or "")
  local buf = buffer_for(view, dir)
  M.bufs[buf].focus = opts.focus
  -- remember the file this window showed, for the close key
  local here = vim.api.nvim_get_current_buf()
  if not M.bufs[here] then vim.w.reviewer_before_browser = here end
  vim.api.nvim_win_set_buf(0, buf)
  M.render_buf(buf, true)
end

-- Leave the browser: back to the file this window showed before it, like
-- oil's close.
function M.close()
  local prev = vim.w.reviewer_before_browser
  if prev and vim.api.nvim_buf_is_valid(prev) and not M.bufs[prev] then
    vim.api.nvim_win_set_buf(0, prev)
  else
    ui.notify("no file to go back to")
  end
end

-- From a reviewed file: open its folder with the cursor on it.
function M.open_here()
  local ctx = require("reviewer.review").current_ctx()
  if not ctx then return M.open({ dir = "" }) end
  local d = vim.fs.dirname(ctx.file.path)
  M.open({ dir = d == "." and "" or d, view = "folders", focus = "file:" .. ctx.file.path })
end

function M.is_browser(buf) return M.bufs[buf] ~= nil end

-- Forget every browser buffer (when the review changes).
function M.wipe()
  for buf in pairs(M.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  M.bufs = {}
end

function M.take_quiz(id)
  local quiz = require("reviewer.quiz")
  require("reviewer.prepare").quiz_or_write(id, function() quiz.reload() ; quiz.open(id) end)
end

core.on_change(function() M.render() ; require("reviewer.render").draw_all() end)

return M
