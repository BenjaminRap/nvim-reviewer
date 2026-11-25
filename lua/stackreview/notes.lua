-- Your notes on lines of reviewed files: note, question to come back to, issue to fix.
local core = require("stackreview.core")
local state = require("stackreview.state")
local render = require("stackreview.render")
local ui = require("stackreview.ui")

local M = {}

local KINDS = {
  { kind = "note", label = "Note" },
  { kind = "question", label = "Question to come back to" },
  { kind = "issue", label = "Issue to fix" },
}

local function range()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    return math.min(a, b), math.max(a, b)
  end
  local l = vim.api.nvim_win_get_cursor(0)[1]
  return l, l
end
M.range = range

function M.add_here(l1, l2)
  local review = require("stackreview.review")
  local ctx = review.current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  if not l1 then l1, l2 = range() end
  local buf = vim.api.nvim_get_current_buf()
  local snippet = table.concat(vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false), "\n"):sub(1, 600)
  vim.ui.select(KINDS, { prompt = "Kind of note", format_item = function(k) return k.label end }, function(choice)
    if not choice then return end
    vim.schedule(function()
      ui.input({ title = ("%s · %s:%d%s"):format(choice.label, vim.fs.basename(ctx.file.path), l1, l2 > l1 and ("-" .. l2) or "") }, function(text)
        local st = state.get(ctx.project)
        table.insert(st.notes, {
          id = state.uid("n-"), step = ctx.step.id, path = ctx.file.path,
          line = l1, end_line = l2, kind = choice.kind, text = text, snippet = snippet,
          done = false, at = state.now(),
        })
        state.save(ctx.project)
        core.changed()
        ui.notify("note saved")
      end)
    end)
  end)
end

local function describe(n)
  local k = render.KIND[n.kind] or render.KIND.note
  return ("%s %s%s · step %s · %s:%d  %s"):format(k.sign, n.done and "(resolved) " or "", k.name, n.step, n.path, n.line or 0, (n.text or ""):gsub("\n", " "):sub(1, 80))
end

function M.jump(n)
  local step = core.project.steps[tonumber(n.step)]
  if not step then return end
  if core.step.id ~= step.id then core.set_step(step.id) end
  require("stackreview.review").open_path(step, n.path, n.line)
end

-- Pick a note: open it, resolve it, or delete it.
function M.list(filter)
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local notes = {}
  for _, n in ipairs(state.get(core.project).notes) do
    if not filter or filter(n) then notes[#notes + 1] = n end
  end
  if #notes == 0 then return ui.notify("no notes yet") end
  table.sort(notes, function(a, b)
    if a.done ~= b.done then return not a.done end
    if a.step ~= b.step then return a.step < b.step end
    if a.path ~= b.path then return a.path < b.path end
    return (a.line or 0) < (b.line or 0)
  end)
  vim.ui.select(notes, { prompt = "Notes", format_item = describe }, function(n)
    if not n then return end
    vim.schedule(function()
      vim.ui.select({ "Open", n.done and "Reopen" or "Resolve", "Edit", "Delete" }, { prompt = describe(n) }, function(action)
        if action == "Open" then M.jump(n)
        elseif action == "Resolve" or action == "Reopen" then n.done = not n.done ; state.save(core.project) ; core.changed()
        elseif action == "Edit" then
          vim.schedule(function()
            ui.input({ title = "Edit note", text = n.text }, function(text) n.text = text ; state.save(core.project) ; core.changed() end)
          end)
        elseif action == "Delete" then
          local st = state.get(core.project)
          for i, x in ipairs(st.notes) do if x.id == n.id then table.remove(st.notes, i) break end end
          state.save(core.project) ; core.changed()
        end
      end)
    end)
  end)
end

-- Notes on the line under the cursor (to resolve or delete quickly).
function M.at_cursor()
  local ctx = require("stackreview.review").current_ctx()
  if not ctx then return end
  local l = vim.api.nvim_win_get_cursor(0)[1]
  M.list(function(n) return n.step == ctx.step.id and n.path == ctx.file.path and (n.line or 0) <= l and (n.end_line or n.line or 0) >= l end)
end

return M
