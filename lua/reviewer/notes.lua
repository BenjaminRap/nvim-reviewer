-- Your own notes on the lines of reviewed files, saved per review with the read
-- marks (state.json: notes[review id] = { note, ... }). A note keeps the text of
-- its first line, so it follows that line when the code above it moves.
local core = require("reviewer.core")
local state = require("reviewer.state")
local ui = require("reviewer.ui")

local M = {}

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

-- The added lines of the changed block holding `line`, or nil.
local function block_of(ctx, line)
  for _, h in ipairs(ctx.hunks or {}) do
    if h.new_count > 0 and line >= h.new_start and line < h.new_start + h.new_count then
      return h.new_start, h.new_start + h.new_count - 1
    end
  end
end

-- The lines a note is about: its own lines, or, for a note on one line of a
-- changed block, the whole block (shown at the top of the block).
function M.span(ctx, n, lines)
  local a, b = M.resolve(n, lines)
  if a == b then
    local s, e = block_of(ctx, a)
    if s then return s, math.min(e, #lines) end
  end
  return a, b
end

-- The note covering `line` in a buffer, or nil (the narrowest one wins).
local function note_at(ctx, lines, line)
  local found, size
  for _, n in ipairs(M.of_file(ctx.file.path, ctx.step)) do
    local a, b = M.span(ctx, n, lines)
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
-- already there. Saving an empty note deletes it.
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
  if existing then l1, l2 = M.span(ctx, existing, lines) end
  if not l1 then
    -- in a changed block, the note is about the whole block
    l1, l2 = block_of(ctx, cur)
  end
  l1, l2 = l1 or cur, l2 or l1 or cur
  local where = ("%s:%d%s"):format(ctx.file.path, l1, l2 > l1 and ("-" .. l2) or "")
  ui.input({
    title = (existing and "Edit note · " or "Note · ") .. where .. (existing and " (empty: delete)" or ""),
    text = existing and existing.text or nil,
    allow_empty = existing ~= nil,
  }, function(text)
    local notes = list(core.project, ctx.step.id, true)
    if existing then
      for i, n in ipairs(notes) do
        if n.id == existing.id then
          if text == "" then table.remove(notes, i) else n.text, n.at = text, state.now() end
          break
        end
      end
      if text == "" then ui.notify("note deleted") end
    else
      notes[#notes + 1] = {
        id = state.uid("n"), path = ctx.file.path, line = l1, end_line = l2,
        code = lines[l1], text = text, at = state.now(),
      }
    end
    state.save(core.project)
    redraw(ctx)
  end)
end

-- Every note of the current review in the quickfix list, by file and line.
function M.quickfix()
  if not (core.project and core.step) then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local dir = require("reviewer.git").step_dir(core.project, core.step, true)
  if not dir then return ui.notify("no checkout for this review", vim.log.levels.ERROR) end
  local items, cache = {}, {}
  for _, n in ipairs(list(core.project, core.step.id)) do
    local file = dir .. "/" .. n.path
    cache[file] = cache[file] or (vim.uv.fs_stat(file) and vim.fn.readfile(file) or {})
    local a = M.resolve(n, cache[file])
    items[#items + 1] = { filename = file, lnum = a, text = (n.text:gsub("\n", " ")) }
  end
  if #items == 0 then return ui.notify("no notes in " .. core.step.label .. " (" .. "add one in a reviewed file)") end
  table.sort(items, function(x, y) return x.filename == y.filename and x.lnum < y.lnum or x.filename < y.filename end)
  vim.fn.setqflist({}, " ", { title = "Review notes · " .. core.step.label, items = items })
  vim.cmd("botright copen")
end

return M
