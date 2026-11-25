-- Parses `git diff -U0` output into hunks, and builds the annotated listing
-- that is sent to Claude (whole file, with added and removed lines marked).
local M = {}

-- Returns a list of hunks:
-- { id = "B1", old_start, old_count, new_start, new_count, removed = {lines}, added = {lines}, label }
function M.parse(text)
  local hunks, h = {}, nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os_ then
      h = {
        old_start = tonumber(os_), old_count = oc == "" and 1 or tonumber(oc),
        new_start = tonumber(ns), new_count = nc == "" and 1 or tonumber(nc),
        removed = {}, added = {},
      }
      hunks[#hunks + 1] = h
    elseif h then
      local c = line:sub(1, 1)
      if c == "+" then h.added[#h.added + 1] = line:sub(2)
      elseif c == "-" then h.removed[#h.removed + 1] = line:sub(2) end
    end
  end
  for i, x in ipairs(hunks) do
    x.id = "B" .. i
    local parts = {}
    if x.new_count > 0 then parts[#parts + 1] = string.format("added new L%d–%d", x.new_start, x.new_start + x.new_count - 1) end
    if x.old_count > 0 then parts[#parts + 1] = string.format("removed old L%d–%d", x.old_start, x.old_start + x.old_count - 1) end
    x.label = table.concat(parts, ", ")
    -- line (1-based, in the new file) where this hunk is shown
    if x.new_count > 0 then x.anchor, x.above = x.new_start, true
    elseif x.new_start == 0 then x.anchor, x.above = 1, true
    else x.anchor, x.above = x.new_start, false end
  end
  return hunks
end

-- Map of new line number -> true for added lines.
function M.added_lines(hunks)
  local set = {}
  for _, h in ipairs(hunks) do
    for l = h.new_start, h.new_start + h.new_count - 1 do
      if h.new_count > 0 then set[l] = true end
    end
  end
  return set
end

-- Whole file with markers, for Claude:
--   "   12 + code" added, "      - code    [old 10]" removed, "   13   code" unchanged,
--   "### B3 (added new L12–14, removed old L10)" before each changed block.
function M.listing(lines, hunks, max_chars)
  local before, after = {}, {}
  for _, h in ipairs(hunks) do
    if h.above then before[h.anchor] = before[h.anchor] or {}; table.insert(before[h.anchor], h)
    else after[h.anchor] = after[h.anchor] or {}; table.insert(after[h.anchor], h) end
  end
  local added = M.added_lines(hunks)
  local out = {}
  local function removed(h)
    out[#out + 1] = string.format("### %s (%s)", h.id, h.label)
    for i, r in ipairs(h.removed) do out[#out + 1] = string.format("      - %s    [old %d]", r, h.old_start + i - 1) end
  end
  for n, l in ipairs(lines) do
    for _, h in ipairs(before[n] or {}) do removed(h) end
    out[#out + 1] = string.format("%5d %s %s", n, added[n] and "+" or " ", l)
    for _, h in ipairs(after[n] or {}) do removed(h) end
  end
  if #lines == 0 then for _, h in ipairs(hunks) do removed(h) end end
  local s = table.concat(out, "\n")
  if max_chars and #s > max_chars then s = s:sub(1, max_chars) .. "\n…(truncated)" end
  return s
end

-- Plain numbered text, for quiz excerpts and answers.
function M.numbered(lines, from, to)
  local out = {}
  from, to = math.max(1, from or 1), math.min(#lines, to or #lines)
  for i = from, to do out[#out + 1] = i .. "| " .. lines[i] end
  return table.concat(out, "\n")
end

return M
