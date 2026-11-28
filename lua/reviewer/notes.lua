-- Your own notes on the lines of reviewed files, saved per review with the read
-- marks (state.json: notes[review id] = { note, ... }). A note keeps the text of
-- its first line, so it follows that line when the code above it moves.
-- Kinds: a note written "? ..." is a question, "! ..." an issue, anything else
-- a plain note. A note can be marked done; a question can get Claude's answer.
local core = require("reviewer.core")
local state = require("reviewer.state")
local ui = require("reviewer.ui")

local M = {}

-- "? text" -> "question", "text"; "! text" -> "issue", "text"; else "note".
function M.parse(text)
  local q = text:match("^%?%s+(.*)$")
  if q then return "question", q end
  local i = text:match("^!%s+(.*)$")
  if i then return "issue", i end
  return "note", text
end

-- The text shown in the note input: the kind's prefix, then the note.
local function with_prefix(n)
  local pre = ({ question = "? ", issue = "! " })[n.kind or "note"] or ""
  return pre .. n.text
end

function M.kind(n) return n.kind or "note" end
function M.is_open(n) return (M.kind(n) == "question" or M.kind(n) == "issue") and not n.done end

-- Notes of a review (a list), created on demand.
local function list(project, step_id, create)
  local st = state.get(project)
  if type(st.notes) ~= "table" then st.notes = {} end
  local l = st.notes[step_id]
  if not l and create then
    l = {}
    st.notes[step_id] = l
  end
  return l or {}
end

-- Notes of one file of the current review.
function M.of_file(path, step)
  step = step or core.step
  if not (core.project and step) then return {} end
  local out = {}
  for _, n in ipairs(list(core.project, step.id)) do
    if n.path == path then out[#out + 1] = n end
  end
  return out
end

function M.count(path, step) return #M.of_file(path, step) end

-- Where a note is now in `lines`: its line if the text still matches, else the
-- nearest line with the same text, else its old line (kept inside the file).
function M.resolve(n, lines)
  local count = #lines
  local function clamp(l) return math.max(1, math.min(count > 0 and count or 1, l)) end
  local span = (n.end_line or n.line) - n.line
  local at = n.line
  if n.code and lines[n.line] ~= n.code then
    local best
    for i, l in ipairs(lines) do
      if l == n.code and (not best or math.abs(i - n.line) < math.abs(best - n.line)) then best = i end
    end
    at = best or n.line
  end
  at = clamp(at)
  return at, clamp(at + span)
end

-- The note covering `line` in a buffer, or nil (the narrowest one wins).
local function note_at(ctx, lines, line)
  local found, size
  for _, n in ipairs(M.of_file(ctx.file.path, ctx.step)) do
    local a, b = M.resolve(n, lines)
    if line >= a and line <= b and (not size or b - a < size) then found, size = n, b - a end
  end
  return found
end

local function redraw(ctx)
  for buf, c in pairs(core.buffers) do
    if c.file.path == ctx.file.path and c.step.id == ctx.step.id then require("reviewer.render").draw(buf) end
  end
  require("reviewer.browser").render()
end

-- Add a note on the cursor line (or the selected lines), or edit the note
-- already there. Saving an empty note deletes it. A note stays on the line
-- it was written on, even inside a big changed block.
function M.edit_here(l1, l2)
  local ctx = require("reviewer.review").current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local mode = vim.fn.mode()
  local sel = false
  if l1 == nil and (mode == "v" or mode == "V" or mode == "\22") then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    l1, l2 = math.min(a, b), math.max(a, b)
    sel = true
  elseif l1 then sel = true end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local existing = not sel and note_at(ctx, lines, cur) or nil
  if existing then l1, l2 = M.resolve(existing, lines) end
  l1, l2 = l1 or cur, l2 or l1 or cur
  local where = ("%s:%d%s"):format(ctx.file.path, l1, l2 > l1 and ("-" .. l2) or "")
  ui.input({
    title = (existing and "Edit note · " or "Note · ") .. where .. (existing and " (empty: delete)" or "")
      .. " · start with ? for a question, ! for an issue",
    text = existing and with_prefix(existing) or nil,
    allow_empty = existing ~= nil,
  }, function(text)
    local notes = list(core.project, ctx.step.id, true)
    local kind, body = M.parse(text)
    if existing then
      for i, n in ipairs(notes) do
        if n.id == existing.id then
          if text == "" then table.remove(notes, i)
          else
            -- a question whose text changed loses its old answer
            if n.answer and (body ~= n.text or kind ~= "question") then n.answer, n.answered_at = nil, nil end
            n.text, n.kind, n.at = body, kind, state.now()
          end
          break
        end
      end
      if text == "" then ui.notify("note deleted") end
    else
      notes[#notes + 1] = {
        id = state.uid("n"), path = ctx.file.path, line = l1, end_line = l2,
        code = lines[l1], text = body, kind = kind, at = state.now(),
      }
    end
    state.save(core.project)
    redraw(ctx)
  end)
end

-- The note under the cursor: done / not done.
function M.toggle_done_here()
  local ctx = require("reviewer.review").current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local n = note_at(ctx, lines, vim.api.nvim_win_get_cursor(0)[1])
  if not n then return ui.notify("no note on this line") end
  n.done = not n.done or nil
  state.save(core.project)
  ui.notify((n.done and "done: " or "not done: ") .. n.text:gsub("\n.*", ""))
  redraw(ctx)
end

-- Claude's answers to your questions covering `line`, as texts for the hover float.
function M.answers_at(ctx, lines, line)
  local out, first, last = {}, nil, nil
  for _, n in ipairs(M.of_file(ctx.file.path, ctx.step)) do
    if n.answer and M.kind(n) == "question" then
      local a, b = M.resolve(n, lines)
      if line >= a and line <= b then
        out[#out + 1] = "**Your question:** " .. n.text .. "\n\n" .. n.answer
        first, last = math.min(first or a, a), math.max(last or b, b)
      end
    end
  end
  return out, first, last
end

local LABEL = { note = "note", question = "question", issue = "issue" }

-- Every note of the current review in the quickfix list, by file and line.
-- filter "open": only open questions and issues.
function M.quickfix(filter)
  if not (core.project and core.step) then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local dir = require("reviewer.git").step_dir(core.project, core.step, true)
  if not dir then return ui.notify("no checkout for this review", vim.log.levels.ERROR) end
  local items, cache = {}, {}
  for _, n in ipairs(list(core.project, core.step.id)) do
    if filter ~= "open" or M.is_open(n) then
      local file = dir .. "/" .. n.path
      cache[file] = cache[file] or (vim.uv.fs_stat(file) and vim.fn.readfile(file) or {})
      local a = M.resolve(n, cache[file])
      local tag = "[" .. LABEL[M.kind(n)] .. (n.done and ", done" or "") .. (n.answer and ", answered" or "") .. "] "
      items[#items + 1] = { filename = file, lnum = a, text = tag .. (n.text:gsub("\n", " ")) }
    end
  end
  if #items == 0 then
    return ui.notify(filter == "open" and ("no open question or issue in " .. core.step.label)
      or ("no notes in " .. core.step.label .. " (add one in a reviewed file)"))
  end
  table.sort(items, function(x, y) return x.filename == y.filename and x.lnum < y.lnum or x.filename < y.filename end)
  vim.fn.setqflist({}, " ", { title = (filter == "open" and "Open questions and issues · " or "Review notes · ") .. core.step.label, items = items })
  vim.cmd("botright copen")
end

-- Lines of a file of the review at its head (for answers and the export).
local function file_lines(path)
  local dir = require("reviewer.git").step_dir(core.project, core.step, true)
  local file = dir and (dir .. "/" .. path)
  return file and vim.uv.fs_stat(file) and vim.fn.readfile(file) or {}
end

-- Where a note is now, from the file's lines (without a buffer).
local function where(n, lines)
  local a, b = M.resolve(n, lines)
  return a, b, ("%s:%d%s"):format(n.path, a, b > a and ("-" .. b) or "")
end

-- Answer every open question of the review that has no answer yet, in one
-- Claude call. The plugin gathers the code; Claude only answers.
function M.answer()
  if not (core.project and core.step) then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local todo = {}
  for _, n in ipairs(list(core.project, core.step.id)) do
    if M.kind(n) == "question" and not n.done and not n.answer then todo[#todo + 1] = n end
  end
  if #todo == 0 then return ui.notify("no open question without an answer in " .. core.step.label) end
  local explain = require("reviewer.explain")
  local paths, parts = {}, {}
  for _, n in ipairs(todo) do
    paths[n.path] = true
    local lines = file_lines(n.path)
    local a, b, loc = where(n, lines)
    local from, to = math.max(1, a - 15), math.min(#lines, b + 15)
    local code = {}
    for i = from, to do code[#code + 1] = ("%5d %s %s"):format(i, (i >= a and i <= b) and ">" or " ", lines[i]) end
    parts[#parts + 1] = ("### Question %s at %s\n%s\nCode (\">\" marks the lines the question is about):\n%s"):format(n.id, loc, n.text, table.concat(code, "\n"))
  end
  local prompt = table.concat({
    require("reviewer.claude").PROJECT_INTRO,
    "",
    explain.step_context(core.project, core.step, 80, paths),
    "",
    "The developer wrote these questions while reviewing. Answer each one: concrete, with path:line, open other files only when the code below and the context above are not enough.",
    "",
    table.concat(parts, "\n\n"),
    "",
    'Reply with only JSON: {"answers": [{"id": "the question id", "answer": "the answer, in Markdown"}]}',
  }, "\n")
  local function run()
    ui.notify(("Claude is answering %d question%s…"):format(#todo, #todo > 1 and "s" or ""))
    local config = require("reviewer.config")
    local dir = require("reviewer.git").step_dir(core.project, core.step, true)
    require("reviewer.claude").run(prompt, { json = true, tools = config.options.claude.ask_tools, cwd = dir, use = "ask" }, function(err, res)
      if err or type(res) ~= "table" or type(res.answers) ~= "table" then
        return ui.notify("answers failed: " .. (err or "unexpected reply"), vim.log.levels.WARN)
      end
      local by_id, got = {}, 0
      for _, n in ipairs(todo) do by_id[n.id] = n end
      for _, a in ipairs(res.answers) do
        local n = type(a) == "table" and by_id[tostring(a.id)]
        if n and a.answer and tostring(a.answer) ~= "" then
          n.answer, n.answered_at = tostring(a.answer), state.now()
          got = got + 1
        end
      end
      state.save(core.project)
      ui.notify(("%d of %d questions answered: %s on a question shows its answer"):format(got, #todo,
        require("reviewer.keys").label(config.options.keymaps.file.show_comment)))
      core.changed()
      require("reviewer.render").draw_all()
    end)
  end
  if require("reviewer.config").options.ai.confirm_prepare == false then return run() end
  vim.ui.select({ "Yes, ask", "No" }, { prompt = ("Answer %d open question%s of %s in one Claude call (%d k characters)?"):format(
    #todo, #todo > 1 and "s" or "", core.step.label, math.floor(#prompt / 1000 + 0.5)) }, function(c)
    if c and c:match("^Yes") then vim.schedule(run) end
  end)
end

-- The issues and open questions of the review, as Markdown in a new buffer,
-- to copy into the merge request. Built from your notes only (no Claude call).
function M.export()
  if not (core.project and core.step) then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local issues, questions, cache = {}, {}, {}
  local all = vim.deepcopy(list(core.project, core.step.id))
  for _, n in ipairs(all) do
    cache[n.path] = cache[n.path] or file_lines(n.path)
    n._a = M.resolve(n, cache[n.path])
  end
  table.sort(all, function(x, y) return x.path == y.path and x._a < y._a or x.path < y.path end)
  for _, n in ipairs(all) do
    local _, _, loc = where(n, cache[n.path])
    local text = n.text:gsub("\n", "\n  ")
    if M.kind(n) == "issue" then
      issues[#issues + 1] = ("- [%s] `%s`: %s"):format(n.done and "x" or " ", loc, text)
    elseif M.kind(n) == "question" and not n.done then
      questions[#questions + 1] = ("- `%s`: %s"):format(loc, text)
    end
  end
  if #issues + #questions == 0 then return ui.notify("no issue or open question in " .. core.step.label) end
  local out = { "# Review " .. core.step.label, "" }
  if #issues > 0 then vim.list_extend(out, { "## Issues", "" }); vim.list_extend(out, issues); out[#out + 1] = "" end
  if #questions > 0 then vim.list_extend(out, { "## Questions", "" }); vim.list_extend(out, questions); out[#out + 1] = "" end
  local text = table.concat(out, "\n")
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.fn.setreg('"', text)
  ui.notify(("%d issue%s, %d open question%s; also copied to the unnamed register"):format(
    #issues, #issues == 1 and "" or "s", #questions, #questions == 1 and "" or "s"))
  return text
end

return M
