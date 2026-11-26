-- Ask Claude about a reviewed file or selected lines. Claude runs in the step's
-- folder with read-only tools, so it can open any file of the repo at that step.
-- Every question and answer is saved and listed in :Review asks and :Review progress.
local config = require("reviewer.config")
local core = require("reviewer.core")
local state = require("reviewer.state")
local claude = require("reviewer.claude")
local diff = require("reviewer.diff")
local explain = require("reviewer.explain")
local ui = require("reviewer.ui")

local M = {}

local function show_answer(a)
  local lines = { "# " .. (a.title or "Answer"), "" }
  lines[#lines + 1] = "**Question** (" .. ui.fmt_date(a.at) .. ")"
  lines[#lines + 1] = ""
  vim.list_extend(lines, vim.split(a.question, "\n"))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**Claude**"
  lines[#lines + 1] = ""
  vim.list_extend(lines, vim.split(a.answer or ("_" .. (a.error or "no answer") .. "_"), "\n"))
  ui.show("Claude", lines, { width = math.min(110, vim.o.columns - 4) })
end
M.show_answer = show_answer

-- Generic: run a question with a context, save it, show the answer.
function M.run(entry, context, cwd)
  ui.notify("asking Claude… (the answer opens when ready)")
  local prompt = context .. "\n\nThe developer's question:\n" .. entry.question
  claude.run(prompt, { tools = config.options.claude.ask_tools, cwd = cwd, use = "ask" }, function(err, text)
    entry.answer = text
    entry.error = err
    entry.at = state.now()
    local st = state.get(core.project)
    table.insert(st.asks, entry)
    state.save(core.project)
    core.changed()
    show_answer(entry)
  end)
end

function M.file_context(ctx, l1, l2)
  local p, s, f = ctx.project, ctx.step, ctx.file
  local e = explain.get(ctx)
  local parts = {
    claude.PROJECT_INTRO,
    "",
    ("Repository %s. The review covers branch %s compared with %s (%s..%s). Your working directory holds the code at the head of the reviewed branch; you may read other files to answer."):format(p.name, s.branch, s.base_branch, s.base_ref, s.head_ref),
    ("Current file: %s (%s, +%d −%d)."):format(f.path, explain.STATUS[f.status] or f.status, f.add, f.del),
  }
  if e then parts[#parts + 1] = "Earlier summary of this file: " .. e.summary .. " " .. e.changes end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "The whole file with this step's changes (\"+\" added, \"-\" removed with old line number; numbers are new line numbers):"
  parts[#parts + 1] = "```"
  parts[#parts + 1] = diff.listing(ctx.lines, ctx.hunks, 120000)
  parts[#parts + 1] = "```"
  if l1 then
    parts[#parts + 1] = ("The question is about lines %d-%d:"):format(l1, l2)
    parts[#parts + 1] = "```"
    parts[#parts + 1] = diff.numbered(ctx.lines, l1, l2)
    parts[#parts + 1] = "```"
  end
  return table.concat(parts, "\n")
end

function M.ask_here(l1, l2)
  local ctx = require("reviewer.review").current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local sel = false
  local mode = vim.fn.mode()
  if l1 == nil and (mode == "v" or mode == "V" or mode == "\22") then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    l1, l2 = math.min(a, b), math.max(a, b)
    sel = true
  elseif l1 then sel = true end
  local title = ("%s%s"):format(ctx.file.path, sel and ((":%d"):format(l1) .. (l2 > l1 and ("-" .. l2) or "")) or "")
  ui.input({ title = "Ask Claude · " .. title }, function(q)
    M.run({ kind = "file", step = ctx.step.id, path = ctx.file.path, line = l1, end_line = l2, question = q, title = title },
      M.file_context(ctx, sel and l1 or nil, l2), ctx.dir)
  end)
end

local function describe(a)
  return ("%s · %s  %s"):format(ui.fmt_date(a.at), a.title or "", (a.question or ""):gsub("\n", " "):sub(1, 70))
end

function M.list()
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local asks = vim.deepcopy(state.get(core.project).asks)
  if #asks == 0 then return ui.notify("no questions asked yet") end
  table.sort(asks, function(a, b) return (a.at or "") > (b.at or "") end)
  vim.ui.select(asks, { prompt = "Questions you asked Claude", format_item = describe }, function(a)
    if a then vim.schedule(function() show_answer(a) end) end
  end)
end

return M
