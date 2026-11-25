-- Side panel listing a step's changed files, with read marks per file, group and folder.
local config = require("reviewer.config")
local core = require("reviewer.core")
local state = require("reviewer.state")
local explain = require("reviewer.explain")
local render = require("reviewer.render")
local ui = require("reviewer.ui")

local M = {
  buf = nil, win = nil, items = {},
  order = nil, hide_read = false, hide_generated = nil,
  collapsed = {},
}
local ns = vim.api.nvim_create_namespace("reviewer_panel")

local keys = require("reviewer.keys")
local function K(name) return keys.label(keys.opts("panel")[name]) end
local function sym(name) return config.options.symbols[name] end

local function help_lines()
  local k = keys.opts("panel")
  local rows = {
    { k.open, "open a file, fold a group, run an action line" },
    { k.fold, "fold or unfold a group or folder" },
    { k.toggle_read, "toggle read (file, group or folder)" },
    { k.read_next, "mark read and open the next unread file" },
    { k.toggle_order, "reading order / folders" },
    { k.toggle_generated, "show or hide generated files" },
    { k.toggle_hide_read, "show or hide read files" },
    { k.pick_step, "choose the step" },
    { { keys.label(k.next_step), keys.label(k.prev_step) }, "next / previous step" },
    { k.explain, "Claude's comments on the file under the cursor" },
    { k.explain_group, "comment every file of the group or folder" },
    { k.about, "about the file under the cursor" },
    { k.prepare, "prepare the step with Claude (overview, comments, quiz)" },
    { k.stop, "stop preparing" },
    { k.overview, "step overview (written first if missing)" },
    { k.quiz, "step quiz (offers to write it if missing)" },
    { k.final_quiz, "final quiz" },
    { k.progress, "progress" },
    { k.notes, "notes" },
    { k.toggle_comments, "show or hide Claude's comments" },
    { k.close, "close the panel" },
    { k.help, "this help" },
  }
  local out = {}
  for _, r in ipairs(rows) do
    local l = keys.labels(r[1])
    if vim.trim(l) ~= "" then out[#out + 1] = ("%-14s %s"):format(l, r[2]) end
  end
  return out
end

-- File icon from mini.icons or nvim-web-devicons, if installed.
local function icon(path)
  if not config.options.panel.icons then return nil end
  local name = vim.fs.basename(path)
  local ok, mi = pcall(require, "mini.icons")
  if ok and type(mi) == "table" and mi.get and _G.MiniIcons then
    local ok2, ic, hl = pcall(mi.get, "file", name)
    if ok2 and ic then return ic, hl end
  end
  local okd, dev = pcall(require, "nvim-web-devicons")
  if okd and dev.get_icon then
    local ic, hl = dev.get_icon(name, name:match("%.([^.]+)$"), { default = true })
    if ic then return ic, hl end
  end
  return nil
end

local function is_open() return M.win and vim.api.nvim_win_is_valid(M.win) end

local function quiz_line(step)
  local ok, quiz = pcall(require, "reviewer.quiz")
  if not ok then return "" end
  local s = quiz.stats("step" .. step.id)
  if not s.total then return "quiz not available" end
  if s.answered == 0 then return ("quiz: %d questions"):format(s.total) end
  return ("quiz %d/%d · %d right · %d partly · %d wrong"):format(s.answered, s.total, s.ok, s.part, s.bad)
end

local function build()
  local project, step = core.project, core.step
  local lines, hls, items = {}, {}, {}
  local function add(text, item, hl)
    lines[#lines + 1] = text
    items[#lines] = item
    if hl then hls[#hls + 1] = { #lines - 1, 0, -1, hl } end
  end
  local function hl_range(l, s, e, group) hls[#hls + 1] = { l - 1, s, e, group } end

  local read, total = core.reviewable(step)
  add(("Step %s/%d · %s"):format(step.id, #project.steps, step.label), { kind = "step" }, "ReviewerHeader")
  add(("%s → %s"):format(step.base_branch, step.branch), nil, "ReviewerDim")
  add(("%d/%d files read · %s"):format(read, total, quiz_line(step)), nil, "ReviewerDim")
  if step.stale then add("! branch moved since the folder was made: :ReviewFetch", nil, "ReviewerPartial") end
  -- Actions (press <CR> on a line, or its key)
  local prep = require("reviewer.prepare")
  local quiz = require("reviewer.quiz")
  local ps = prep.status(step.id)
  local s = prep.step_state(step)
  local show_actions = config.options.panel.show_actions
  if ps and not show_actions then add(ps, nil, "ReviewerPartial") end
  if show_actions then
  add("")
  if ps then
    add(ps, nil, "ReviewerPartial")
    add(("%s %s  stop preparing"):format(sym("stop"), K("stop")), { kind = "action", run = function() prep.command({ "stop" }) end }, "ReviewerAction")
  elseif not (s.overview and s.commented >= s.total and s.quiz) then
    add(("%s %s  prepare this step with Claude (comments %d/%d)"):format(sym("action"), K("prepare"), s.commented, s.total), { kind = "action", run = function() prep.step(step) end }, "ReviewerAction")
  end
  add(("%s %s  "):format(sym("action"), K("overview")) .. (s.overview and "step overview" or "write the step overview (1 call)"), { kind = "action", run = function() prep.overview_then_show(step) end }, "ReviewerAction")
  local qs = quiz.stats("step" .. step.id)
  add(("%s %s  "):format(sym("action"), K("quiz")) .. (s.quiz and ("step quiz (%d/%d answered)"):format(qs.answered, qs.total or 0) or "write the step quiz"), { kind = "action", run = function() M.take_quiz("step" .. step.id) end }, "ReviewerAction")
  local fs = quiz.stats("final")
  add(("%s %s  "):format(sym("action"), K("final_quiz")) .. (fs.total and ("final quiz (%d/%d answered)"):format(fs.answered, fs.total) or "write the final quiz"), { kind = "action", run = function() M.take_quiz("final") end }, "ReviewerAction")
  if core.current and core.current.step.id == step.id and not core.current.file.generated and not explain.get(core.current) then
    local ctx = core.current
    add(("%s %s  comment "):format(sym("action"), K("explain")) .. vim.fs.basename(ctx.file.path), { kind = "action", run = function() require("reviewer.review").explain_ctx(ctx, false) end }, "ReviewerAction")
  end
  end
  add("")

  local files = core.ordered(step, { hide_generated = M.hide_generated, order = M.order })
  local cur = core.current and core.current.step.id == step.id and core.current.file.path or nil
  local notes_count = {}
  for _, n in ipairs(state.get(project).notes) do
    if n.step == step.id and not n.done then notes_count[n.path] = (notes_count[n.path] or 0) + 1 end
  end
  local ex = state.explain(project).files

  local function file_line(f, indent, label, hint)
    local r = core.is_read(f.path, step)
    if M.hide_read and r and f.path ~= cur then return end
    local ic, ic_hl = icon(f.path)
    local head = ("%s[%s] %s "):format(indent, r and sym("read") or sym("unread"), f.status)
    local text = head .. (ic and (ic .. " ") or "") .. label
    local tail = ""
    if hint and hint ~= "" then tail = tail .. "  " .. hint end
    local stats = f.binary and "  bin" or ("  +%d −%d"):format(f.add, f.del)
    tail = tail .. stats
    if notes_count[f.path] then tail = tail .. "  " .. sym("note") .. notes_count[f.path] end
    if ex[step.id .. "|" .. f.path] then tail = tail .. " " .. sym("comment") end
    if explain.status[step.id .. "|" .. f.path] == "pending" then tail = tail .. " " .. sym("pending") end
    add(text .. tail, { kind = "file", file = f })
    local l = #lines
    if r then hl_range(l, 0, -1, "ReviewerRead") end
    if ic and ic_hl and not r then hl_range(l, #head, #head + #ic, ic_hl) end
    local s = #text
    if hint and hint ~= "" then hl_range(l, s, s + 2 + #hint, "ReviewerDim") ; s = s + 2 + #hint end
    local plus = stats:match("^  %+%d+") or ""
    if not f.binary then
      hl_range(l, s + 2, s + #plus, "ReviewerAddSign")
      hl_range(l, s + #plus, s + #stats, "ReviewerDeleteSign")
    end
    if f.path == cur then hl_range(l, 0, -1, "ReviewerCurrent") end
  end

  local function group_line(key, label, indent, paths)
    local done = 0
    for _, p in ipairs(paths) do if core.is_read(p, step) then done = done + 1 end end
    local mark = done == 0 and sym("unread") or (done == #paths and sym("read") or sym("partly_read"))
    local folded = M.collapsed[step.id .. ":" .. key]
    add(("%s%s [%s] %s  %d/%d"):format(indent, folded and sym("fold_closed") or sym("fold_open"), mark, label, done, #paths), { kind = "group", key = key, paths = paths }, "ReviewerGroup")
    return folded
  end

  if (M.order or config.options.order) == "reading" then
    local groups, order = {}, {}
    for _, f in ipairs(files) do
      local g = core.group_of(f)
      if not groups[g.label] then groups[g.label] = { g = g, files = {} } ; order[#order + 1] = g.label end
      table.insert(groups[g.label].files, f)
    end
    for _, label in ipairs(order) do
      local grp = groups[label]
      local paths = vim.tbl_map(function(f) return f.path end, grp.files)
      if not group_line("g:" .. label, label, "", paths) then
        for _, f in ipairs(grp.files) do
          local dir = vim.fs.dirname(f.path)
          dir = dir == "." and "" or dir:gsub("^src/", "")
          file_line(f, "  ", vim.fs.basename(f.path), dir)
        end
      end
      add("")
    end
  else
    local root = { dirs = {}, names = {}, files = {} }
    for _, f in ipairs(files) do
      local node = root
      local parts = vim.split(f.path, "/")
      for i = 1, #parts - 1 do
        local p = parts[i]
        if not node.dirs[p] then node.dirs[p] = { dirs = {}, names = {}, files = {} } ; table.insert(node.names, p) end
        node = node.dirs[p]
      end
      table.insert(node.files, f)
    end
    local function all(node, acc)
      acc = acc or {}
      for _, f in ipairs(node.files) do acc[#acc + 1] = f.path end
      for _, n in ipairs(node.names) do all(node.dirs[n], acc) end
      return acc
    end
    local function walk(node, depth, prefix)
      table.sort(node.names)
      for _, name in ipairs(node.names) do
        local child, label, path = node.dirs[name], name, prefix .. name
        while #child.files == 0 and #child.names == 1 do
          local nn = child.names[1]
          label, path, child = label .. "/" .. nn, path .. "/" .. nn, child.dirs[nn]
        end
        if not group_line("d:" .. path, label .. "/", string.rep("  ", depth), all(child)) then walk(child, depth + 1, path .. "/") end
      end
      for _, f in ipairs(node.files) do file_line(f, string.rep("  ", depth), vim.fs.basename(f.path)) end
    end
    walk(root, 0, "")
    add("")
  end

  if config.options.panel.show_file_summary and core.current and core.current.step.id == step.id then
    local e = explain.get(core.current)
    add("── " .. core.current.file.path:match("[^/]+$") .. " ──", nil, "ReviewerHeader")
    if e then
      for _, l in ipairs(ui.wrap(e.summary, (config.options.panel.width or 48) - 2)) do add(l) end
    else
      local s = explain.status[explain.key(core.current)]
      add(s == "pending" and "Claude is writing comments…" or (s and s:sub(1, 60)) or ("no comments yet (" .. K("explain") .. ")"), nil, "ReviewerDim")
    end
    add("")
  end
  if K("help") ~= "" then add(K("help") .. " help", nil, "ReviewerDim") end
  return lines, hls, items
end

function M.render()
  if not is_open() or not core.project then return end
  local ok, lines, hls, items = pcall(build)
  if not ok then lines, hls, items = { "error: " .. tostring(lines) }, {}, {} end
  M.items = items
  local cursor = vim.api.nvim_win_get_cursor(M.win)
  ui.set_lines(M.buf, lines)
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local line_len = #(lines[h[1] + 1] or "")
    pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, h[1], h[2], { end_col = h[3] == -1 and line_len or math.min(h[3], line_len), hl_group = h[4], hl_eol = h[3] == -1, priority = h[4] == "ReviewerCurrent" and 5 or 10 })
  end
  pcall(vim.api.nvim_win_set_cursor, M.win, { math.min(cursor[1], #lines), cursor[2] })
end

local function item_at_cursor()
  return M.items[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function act(fn) return function() local it = item_at_cursor() ; if it then fn(it) end end end

local function setup_keys(buf)
  local review = require("reviewer.review")
  local k = keys.opts("panel")
  local function map(lhs, fn, desc) keys.map(buf, "n", lhs, fn, desc) end
  local function fold(it)
    if it.kind == "group" then
      local key = core.step.id .. ":" .. it.key
      M.collapsed[key] = not M.collapsed[key]
      M.render()
    end
  end
  map(k.open, act(function(it)
    if it.kind == "action" then it.run()
    elseif it.kind == "file" then review.open(core.step, it.file)
    else fold(it) end
  end), "open")
  map(k.fold, act(fold), "fold")
  map(k.toggle_read, act(function(it)
    if it.kind == "file" then
      state.set_read(core.project, core.step.id, { it.file.path }, not core.is_read(it.file.path))
    elseif it.kind == "group" then
      local all = true
      for _, p in ipairs(it.paths) do if not core.is_read(p) then all = false end end
      state.set_read(core.project, core.step.id, it.paths, not all)
    end
    core.changed()
  end), "toggle read")
  map(k.read_next, function() review.read_next() end, "mark read and open the next unread file")
  map(k.toggle_order, function() M.order = (M.order == "tree") and "reading" or "tree" ; M.render() end, "reading order / folders")
  map(k.toggle_generated, function() M.hide_generated = not M.hide_generated ; M.render() end, "show or hide generated files")
  map(k.toggle_hide_read, function() M.hide_read = not M.hide_read ; M.render() end, "show or hide read files")
  map(k.pick_step, function() M.pick_step() end, "choose the step")
  map(k.next_step, function() core.set_step(math.min(#core.project.steps, core.step.index + 1)) end, "next step")
  map(k.prev_step, function() core.set_step(math.max(1, core.step.index - 1)) end, "previous step")
  map(k.explain, act(function(it)
    if it.kind == "file" then review.explain_ctx(core.make_ctx(core.step, it.file), false)
    elseif it.kind == "action" then it.run() end
  end), "Claude's comments on the file")
  map(k.explain_group, act(function(it)
    local paths = it.kind == "group" and it.paths or (it.kind == "file" and { it.file.path }) or nil
    if paths then require("reviewer.prepare").paths(core.step, paths) end
  end), "comment every file of the group")
  map(k.about, act(function(it) if it.kind == "file" then review.open(core.step, it.file) ; review.about() end end), "about the file")
  map(k.prepare, function() require("reviewer.prepare").step(core.step) end, "prepare the step")
  map(k.stop, function() require("reviewer.prepare").command({ "stop" }) end, "stop preparing")
  map(k.overview, function() require("reviewer.prepare").overview_then_show(core.step) end, "step overview")
  map(k.quiz, function() M.take_quiz("step" .. core.step.id) end, "step quiz")
  map(k.final_quiz, function() M.take_quiz("final") end, "final quiz")
  map(k.progress, function() require("reviewer.progress").open() end, "progress")
  map(k.notes, function() require("reviewer.notes").list() end, "notes")
  map(k.toggle_comments, function() review.toggle_comments() end, "show or hide comments")
  map(k.close, function() M.close() end, "close the panel")
  map(k.help, function() local h = help_lines() ; ui.show("Review panel keys", h, { width = 76, height = #h + 2 }) end, "help")
end

function M.take_quiz(id)
  local quiz = require("reviewer.quiz")
  require("reviewer.prepare").quiz_or_write(id, function() quiz.reload() ; quiz.open(id) end)
end

function M.pick_step()
  local items = {}
  for _, s in ipairs(core.project.steps) do
    local r, t = core.reviewable(s)
    items[#items + 1] = { step = s, label = ("%s. %s  (%d/%d read)"):format(s.id, s.label, r, t) }
  end
  vim.ui.select(items, { prompt = "Review step", format_item = function(i) return i.label end }, function(choice)
    if choice then core.set_step(choice.step.id) end
  end)
end

function M.open()
  if M.order == nil then M.order = config.options.order end
  if M.hide_generated == nil then M.hide_generated = config.options.hide_generated end
  if is_open() then vim.api.nvim_set_current_win(M.win) ; M.render() ; return end
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "reviewer://panel")
    vim.bo[M.buf].filetype = "reviewer"
    vim.bo[M.buf].bufhidden = "hide"
    setup_keys(M.buf)
  end
  vim.cmd((config.options.panel.position == "right" and "botright" or "topleft") .. " vsplit")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_width(M.win, config.options.panel.width or 48)
  for k, v in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, cursorline = true, winfixwidth = true, foldcolumn = "0", spell = false, list = false }) do
    vim.wo[M.win][k] = v
  end
  M.render()
end

function M.close()
  if is_open() then pcall(vim.api.nvim_win_close, M.win, true) end
  M.win = nil
end

function M.toggle() if is_open() then M.close() else M.open() end end

core.on_change(function() M.render() ; render.draw_all() end)

return M
