-- One view of everything remembered: files read, quiz results, mistakes,
-- questions asked to Claude, open notes.
local core = require("reviewer.core")
local state = require("reviewer.state")
local ui = require("reviewer.ui")

local M = {}

function M.open()
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local quiz = require("reviewer.quiz")
  local keys = require("reviewer.keys")
  local k = keys.opts("progress")
  local st = state.get(core.project)
  local lines, targets = {}, {}
  local function add(t, target) lines[#lines + 1] = t ; if target then targets[#lines] = target end end

  add("# Review progress: " .. core.project.name)
  add("")
  add("| Step | Files read | Quiz | Results |")
  add("|---|---|---|---|")
  for _, s in ipairs(core.project.steps) do
    local r, t = core.reviewable(s)
    local q = quiz.stats("step" .. s.id)
    add(("| %s. %s | %d/%d | %s | %s |"):format(s.id, s.label, r, t, q.total and (q.answered .. "/" .. q.total) or "—",
      q.answered > 0 and ("%d right · %d partly · %d wrong"):format(q.ok, q.part, q.bad) or "—"), { kind = "step", step = s })
  end
  local f = quiz.stats("final")
  if f.total then
    add(("| Final quiz | — | %d/%d | %s |"):format(f.answered, f.total, f.answered > 0 and ("%d right · %d partly · %d wrong"):format(f.ok, f.part, f.bad) or "—"), { kind = "quiz", quiz = "final" })
  end

  local mistakes = {}
  for _, a in pairs(st.attempts) do
    if a.last and a.last.verdict ~= "correct" then mistakes[#mistakes + 1] = a end
  end
  table.sort(mistakes, function(a, b) return (a.last.at or "") > (b.last.at or "") end)
  add("")
  add(("## Mistakes to work on (%d)%s"):format(#mistakes, #mistakes > 0 and ("  ·  %s: retry them all"):format(keys.label(k.retry_mistakes)) or ""))
  add("")
  for i, a in ipairs(mistakes) do
    if i > 60 then add("…") break end
    add(("- [%s · L%s] %s %s"):format(a.quiz == "final" and "final" or a.quiz:gsub("step", "step "), a.level or "?", a.last.verdict == "partial" and "~" or "✗",
      (a.prompt or ""):gsub("\n", " "):sub(1, 110)), { kind = "question", quiz = a.quiz, qid = a.qid })
  end

  local asks = vim.deepcopy(st.asks)
  table.sort(asks, function(a, b) return (a.at or "") > (b.at or "") end)
  add("")
  add(("## Questions you asked Claude (%d)"):format(#asks))
  add("")
  for i, a in ipairs(asks) do
    if i > 40 then add("…  (:ReviewAsks lists them all)") break end
    add(("- %s · %s — %s"):format(ui.fmt_date(a.at), a.title or "", (a.question or ""):gsub("\n", " "):sub(1, 90)), { kind = "ask", ask = a })
  end

  local open, by = 0, { note = 0, question = 0, issue = 0, ai = 0 }
  for _, n in ipairs(st.notes) do
    if not n.done then open = open + 1 ; by[n.kind] = (by[n.kind] or 0) + 1 end
  end
  add("")
  add(("## Open notes: %d (%d issues, %d questions, %d notes)  ·  %s: list them"):format(open, by.issue, by.question, by.note, keys.label(k.notes)))
  add("")
  add(("_%s on a line opens it · %s retry mistakes · %s notes · %s questions asked · %s close_"):format(keys.label(k.open), keys.label(k.retry_mistakes), keys.label(k.notes), keys.label(k.asks), keys.label(keys.opts("float").close)))

  local buf = ui.show("Review progress", lines, { width = math.min(120, vim.o.columns - 4) })
  local function map(lhs, fn, desc) keys.map(buf, "n", lhs, fn, desc or "progress") end
  local function close() vim.cmd("close") end
  map(k.open, function()
    local t = targets[vim.api.nvim_win_get_cursor(0)[1]]
    if not t then return end
    close()
    if t.kind == "step" then core.set_step(t.step.id) ; require("reviewer.panel").open()
    elseif t.kind == "quiz" then quiz.open(t.quiz)
    elseif t.kind == "question" then quiz.open_question(t.quiz, t.qid)
    elseif t.kind == "ask" then require("reviewer.ask").show_answer(t.ask) end
  end)
  map(k.retry_mistakes, function() close() ; quiz.open("mistakes") end)
  map(k.notes, function() close() ; require("reviewer.notes").list() end)
  map(k.asks, function() close() ; require("reviewer.ask").list() end)
end

return M
