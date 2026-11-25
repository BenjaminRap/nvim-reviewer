-- Side panel listing a step's changed files, with read marks per file, group and folder.
local config = require("stackreview.config")
local core = require("stackreview.core")
local state = require("stackreview.state")
local explain = require("stackreview.explain")
local render = require("stackreview.render")
local ui = require("stackreview.ui")

local M = {
  buf = nil, win = nil, items = {},
  order = nil, hide_read = false, hide_generated = nil,
  collapsed = {},
}
local ns = vim.api.nvim_create_namespace("stackreview_panel")

local HELP = {
  "<CR> o  open file            x  toggle read (file, group or folder)",
  "<Tab>   fold group/folder    n  mark read and open next unread",
  "t       reading order/folders  g  show/hide generated files",
  "h       hide/show read files   s  choose step   ]s [s  next/prev step",
  "e       comment file again     a  about the file under the cursor",
  "A       prepare the step with Claude (overview, comments, quiz)   S  stop",
  "O       step overview (written first if missing)",
  "E       comment every file of the group/folder (or the file under the cursor)",
  "Q  F    step quiz / final quiz (offers to write it if missing)",
  "P       progress               N  notes",
  "C       show/hide comments     q  close panel   ?  this help",
}

local function is_open() return M.win and vim.api.nvim_win_is_valid(M.win) end

local function quiz_line(step)
  local ok, quiz = pcall(require, "stackreview.quiz")
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
  add(("Step %s/%d · %s"):format(step.id, #project.steps, step.label), { kind = "step" }, "StackReviewHeader")
  add(("%s → %s"):format(step.base_branch, step.branch), nil, "StackReviewDim")
  add(("%d/%d files read · %s"):format(read, total, quiz_line(step)), nil, "StackReviewDim")
  if step.stale then add("! branch moved since the folder was made: :ReviewFetch", nil, "StackReviewPartial") end
  -- Actions (press <CR> on a line, or its key)
  local prep = require("stackreview.prepare")
  local quiz = require("stackreview.quiz")
  local ps = prep.status(step.id)
  local s = prep.step_state(step)
  add("")
  if ps then
    add(ps, nil, "StackReviewPartial")
    add("■ S  stop preparing", { kind = "action", run = function() prep.command({ "stop" }) end }, "StackReviewAction")
  elseif not (s.overview and s.commented >= s.total and s.quiz) then
    add(("▶ A  prepare this step with Claude (comments %d/%d)"):format(s.commented, s.total), { kind = "action", run = function() prep.step(step) end }, "StackReviewAction")
  end
  add("▶ O  " .. (s.overview and "step overview" or "write the step overview (1 call)"), { kind = "action", run = function() prep.overview_then_show(step) end }, "StackReviewAction")
  local qs = quiz.stats("step" .. step.id)
  add("▶ Q  " .. (s.quiz and ("step quiz (%d/%d answered)"):format(qs.answered, qs.total or 0) or "write the step quiz"), { kind = "action", run = function() M.take_quiz("step" .. step.id) end }, "StackReviewAction")
  local fs = quiz.stats("final")
  add("▶ F  " .. (fs.total and ("final quiz (%d/%d answered)"):format(fs.answered, fs.total) or "write the final quiz"), { kind = "action", run = function() M.take_quiz("final") end }, "StackReviewAction")
  if core.current and core.current.step.id == step.id and not core.current.file.generated and not explain.get(core.current) then
    local ctx = core.current
    add("▶ e  comment " .. vim.fs.basename(ctx.file.path), { kind = "action", run = function() require("stackreview.review").explain_ctx(ctx, false) end }, "StackReviewAction")
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
    local text = ("%s[%s] %s %s"):format(indent, r and "x" or " ", f.status, label)
    local tail = ""
    if hint and hint ~= "" then tail = tail .. "  " .. hint end
    local stats = f.binary and "  bin" or ("  +%d −%d"):format(f.add, f.del)
    tail = tail .. stats
    if notes_count[f.path] then tail = tail .. "  ●" .. notes_count[f.path] end
    if ex[step.id .. "|" .. f.path] then tail = tail .. " ✦" end
    if explain.status[step.id .. "|" .. f.path] == "pending" then tail = tail .. " …" end
    add(text .. tail, { kind = "file", file = f })
    local l = #lines
    if r then hl_range(l, 0, -1, "StackReviewRead") end
    local s = #text
    if hint and hint ~= "" then hl_range(l, s, s + 2 + #hint, "StackReviewDim") ; s = s + 2 + #hint end
    local plus = stats:match("^  %+%d+") or ""
    if not f.binary then
      hl_range(l, s + 2, s + #plus, "StackReviewAddSign")
      hl_range(l, s + #plus, s + #stats, "StackReviewDeleteSign")
    end
    if f.path == cur then hl_range(l, 0, -1, "StackReviewCurrent") end
  end

  local function group_line(key, label, indent, paths)
    local done = 0
    for _, p in ipairs(paths) do if core.is_read(p, step) then done = done + 1 end end
    local mark = done == 0 and " " or (done == #paths and "x" or "-")
    local folded = M.collapsed[step.id .. ":" .. key]
    add(("%s%s [%s] %s  %d/%d"):format(indent, folded and "▸" or "▾", mark, label, done, #paths), { kind = "group", key = key, paths = paths }, "StackReviewGroup")
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

  if core.current and core.current.step.id == step.id then
    local e = explain.get(core.current)
    add("── " .. core.current.file.path:match("[^/]+$") .. " ──", nil, "StackReviewHeader")
    if e then
      for _, l in ipairs(ui.wrap(e.summary, (config.options.panel.width or 48) - 2)) do add(l) end
    else
      local s = explain.status[explain.key(core.current)]
      add(s == "pending" and "Claude is writing comments…" or (s and s:sub(1, 60)) or "no comments yet (e)", nil, "StackReviewDim")
    end
    add("")
  end
  add("? help", nil, "StackReviewDim")
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
    pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, h[1], h[2], { end_col = h[3] == -1 and line_len or math.min(h[3], line_len), hl_group = h[4], hl_eol = h[3] == -1, priority = h[4] == "StackReviewCurrent" and 5 or 10 })
  end
  pcall(vim.api.nvim_win_set_cursor, M.win, { math.min(cursor[1], #lines), cursor[2] })
end

local function item_at_cursor()
  return M.items[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function act(fn) return function() local it = item_at_cursor() ; if it then fn(it) end end end

local function setup_keys(buf)
  local review = require("stackreview.review")
  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  local open = act(function(it)
    if it.kind == "action" then it.run()
    elseif it.kind == "file" then review.open(core.step, it.file)
    elseif it.kind == "group" then M.collapsed[core.step.id .. ":" .. it.key] = not M.collapsed[core.step.id .. ":" .. it.key] ; M.render() end
  end)
  map("<CR>", open) ; map("o", open)
  map("<Tab>", act(function(it)
    if it.kind == "group" then M.collapsed[core.step.id .. ":" .. it.key] = not M.collapsed[core.step.id .. ":" .. it.key] ; M.render() end
  end))
  map("x", act(function(it)
    if it.kind == "file" then
      state.set_read(core.project, core.step.id, { it.file.path }, not core.is_read(it.file.path))
    elseif it.kind == "group" then
      local all = true
      for _, p in ipairs(it.paths) do if not core.is_read(p) then all = false end end
      state.set_read(core.project, core.step.id, it.paths, not all)
    end
    core.changed()
  end))
  map("n", function() review.read_next() end)
  map("t", function() M.order = (M.order == "tree") and "reading" or "tree" ; M.render() end)
  map("g", function() M.hide_generated = not M.hide_generated ; M.render() end)
  map("h", function() M.hide_read = not M.hide_read ; M.render() end)
  map("s", function() M.pick_step() end)
  map("]s", function() core.set_step(math.min(#core.project.steps, core.step.index + 1)) end)
  map("[s", function() core.set_step(math.max(1, core.step.index - 1)) end)
  map("e", act(function(it)
    if it.kind ~= "file" then return end
    review.explain_ctx(core.make_ctx(core.step, it.file), false)
  end))
  map("a", act(function(it) if it.kind == "file" then review.open(core.step, it.file) ; review.about() end end))
  map("Q", function() M.take_quiz("step" .. core.step.id) end)
  map("F", function() M.take_quiz("final") end)
  map("O", function() require("stackreview.prepare").overview_then_show(core.step) end)
  map("A", function() require("stackreview.prepare").step(core.step) end)
  map("S", function() require("stackreview.prepare").command({ "stop" }) end)
  map("E", act(function(it)
    local paths = it.kind == "group" and it.paths or (it.kind == "file" and { it.file.path }) or nil
    if paths then require("stackreview.prepare").paths(core.step, paths) end
  end))
  map("P", function() require("stackreview.progress").open() end)
  map("N", function() require("stackreview.notes").list() end)
  map("C", function() review.toggle_comments() end)
  map("q", function() M.close() end)
  map("?", function() ui.show("Review panel keys", HELP, { width = 72, height = #HELP + 2 }) end)
end

function M.take_quiz(id)
  local quiz = require("stackreview.quiz")
  require("stackreview.prepare").quiz_or_write(id, function() quiz.reload() ; quiz.open(id) end)
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
    vim.api.nvim_buf_set_name(M.buf, "stackreview://panel")
    vim.bo[M.buf].filetype = "stackreview"
    vim.bo[M.buf].bufhidden = "hide"
    setup_keys(M.buf)
  end
  vim.cmd("topleft vsplit")
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
