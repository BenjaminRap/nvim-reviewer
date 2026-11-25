-- Quizzes from the big picture down to single lines. Choice questions are graded
-- here; open answers are graded by Claude against a reference answer.
-- Quiz files: <quiz_dir>/quiz-*.json, each { id, title, ref, questions = [...] }.
local core = require("reviewer.core")
local state = require("reviewer.state")
local claude = require("reviewer.claude")
local diff = require("reviewer.diff")
local git = require("reviewer.git")
local ui = require("reviewer.ui")
local config = require("reviewer.config")

local M = { s = nil, buf = nil, win = nil }
local ns = vim.api.nvim_create_namespace("reviewer_quiz")
local LEVELS = { "Architecture", "Flows & design", "Files & responsibilities", "Implementation", "Line-level details" }
M.LEVELS = LEVELS
local LETTERS = "abcdef" -- choice labels shown and sent to Claude
local keys = require("reviewer.keys")
local function TW() return config.options.float.text_width or 96 end
local function KL(name) return keys.labels(keys.opts("quiz")[name]) end

local quizzes -- id -> quiz

local function load()
  if quizzes then return quizzes end
  quizzes = {}
  if not core.project then return quizzes end
  for _, path in ipairs(vim.fn.glob(core.project.quiz_dir .. "/quiz-*.json", false, true)) do
    local f = io.open(path, "r")
    if f then
      local ok, q = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
      f:close()
      if ok and type(q) == "table" and q.id and q.questions then
        table.sort(q.questions, function(a, b)
          if a.level ~= b.level then return a.level < b.level end
          local na, nb = tonumber(a.id:match("(%d+)$")) or 0, tonumber(b.id:match("(%d+)$")) or 0
          return na < nb
        end)
        quizzes[q.id] = q
      else
        ui.notify("could not read quiz " .. path, vim.log.levels.WARN)
      end
    end
  end
  return quizzes
end
function M.reload() quizzes = nil ; return load() end

function M.ids()
  local ids = vim.tbl_keys(load())
  table.sort(ids)
  return ids
end

local function question(quiz_id, id)
  local q = load()[quiz_id]
  if not q then return nil end
  for _, x in ipairs(q.questions) do if x.id == id then return x end end
end

local function attempts() return state.get(core.project).attempts end

function M.stats(quiz_id)
  local q = load()[quiz_id]
  local s = { total = q and #q.questions or nil, answered = 0, ok = 0, part = 0, bad = 0 }
  if not q then return s end
  local at = attempts()
  for _, x in ipairs(q.questions) do
    local a = at[x.id]
    if a and a.last then
      s.answered = s.answered + 1
      if a.last.verdict == "correct" then s.ok = s.ok + 1 elseif a.last.verdict == "partial" then s.part = s.part + 1 else s.bad = s.bad + 1 end
    end
  end
  return s
end

local function title(quiz_id)
  if quiz_id == "mistakes" then return "Your mistakes, all quizzes" end
  return "Quiz: " .. (quiz_id or ""):gsub("%.%.", " → ")
end

-- The review a quiz is about (its refs are at that review's head branch).
local function quiz_step(quiz_id)
  if core.step and quiz_id == core.step.id then return core.step end
  return core.review(core.project, quiz_id) or core.step
end

--------------------------------------------------------------------------- render
local function cur()
  local s = M.s
  if not s or not s.items[s.pos] then return nil end
  local it = s.items[s.pos]
  return it, question(it.quiz, it.id)
end

local function verdict_text(r)
  if not r then return "" end
  local v = ({ correct = "✓ Right", partial = "~ Partly right", wrong = "✗ Wrong" })[r.verdict] or r.verdict
  if type(r.score) == "number" and r.verdict ~= "correct" and r.verdict ~= "wrong" then v = v .. (" (%d%%)"):format(math.floor(r.score * 100 + 0.5)) end
  return v
end

local function render()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
  local s = M.s
  local it, q = cur()
  local lines, marks = {}, {}
  local function add(t) lines[#lines + 1] = t end
  local function addw(t, w) for _, l in ipairs(ui.wrap(t, w or TW())) do add(l) end end
  if not q then
    add("# " .. title(s.quiz))
    add("")
    add(#s.items == 0 and "Nothing to answer here." or "End of this run. Your answers are saved.")
    add("")
    add("Press `o` for the overview, `q` to close.")
    ui.set_lines(M.buf, lines)
    return
  end
  local r = s.result
  local prev = attempts()[q.id]
  add(("# %s"):format(title(it.quiz)))
  add(("Question %d of %d · Level %s · %s · %s · %s"):format(s.pos, #s.items, q.level, LEVELS[q.level] or "", q.topic or "", q.type == "open" and "answer in your own words" or q.type == "multi" and "several answers" or "one answer"))
  if prev and prev.last and not r then
    add(("Last time: %s (%s, %d tr%s)"):format(verdict_text(prev.last), ui.fmt_date(prev.last.at), #(prev.history or {}), #(prev.history or {}) > 1 and "ies" or "y"))
  end
  add("")
  addw(q.prompt)
  if q.code and q.code ~= "" then
    add("")
    add("```" .. (q.codeLang or ""))
    vim.list_extend(lines, vim.split(q.code, "\n"))
    add("```")
  end
  add("")
  local choice_lines = {}
  M.choice_at = {}
  if q.type == "open" then
    if s.text ~= "" then
      add("**Your answer:**")
      addw(s.text)
    else
      add("_Press `i` to write your answer._")
    end
  else
    local answer = {}
    for _, a in ipairs(q.answer or {}) do answer[a + 1] = true end
    for i, c in ipairs(q.choices or {}) do
      local picked = s.sel[i] and "x" or " "
      local w = ui.wrap(c, TW() - 6)
      add(("[%s] %s. %s"):format(picked, LETTERS:sub(i, i), w[1] or ""))
      choice_lines[i] = #lines
      M.choice_at = M.choice_at or {}
      M.choice_at[#lines] = i
      for j = 2, #w do add("       " .. w[j]) end
      if r then
        if answer[i] then marks[#marks + 1] = { choice_lines[i], "ReviewerAdd" }
        elseif s.sel[i] then marks[#marks + 1] = { choice_lines[i], "ReviewerDelete" } end
      end
    end
  end
  add("")
  if s.busy then
    add("_Claude is grading your answer…_")
  elseif r then
    add("## " .. verdict_text(r))
    if r.feedback and r.feedback ~= "" then add("") ; add("**Feedback**") ; addw(r.feedback) end
    if r.missing and #r.missing > 0 then
      add("") ; add("**What was missing**")
      for _, m in ipairs(r.missing) do addw("- " .. m) end
    end
    if q.reference and q.reference ~= "" then add("") ; add(q.type == "open" and "**Reference answer**" or "**In short**") ; addw(q.reference) end
    if q.explanation and q.explanation ~= "" then add("") ; add("**Why**") ; addw(q.explanation) end
    if q.refs and #q.refs > 0 then
      add("") ; add("**See the code** (press its key)")
      local ref_keys = keys.list(keys.opts("quiz").refs)
      for i, ref in ipairs(q.refs) do
        if i > math.max(#ref_keys, 1) then break end
        add(("  %s. %s:%s%s"):format(keys.list(keys.opts("quiz").refs)[i] or tostring(i), ref.path, ref.line or "", (ref.endLine and ref.endLine ~= ref.line) and ("-" .. ref.endLine) or ""))
      end
    end
    if r.self_grade then add("") ; add(("**How did you do?**  `%s` I had it · `%s` partly · `%s` I missed it"):format(KL("self_correct"), KL("self_partial"), KL("self_wrong"))) end
  end
  ui.set_lines(M.buf, lines)
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(M.buf, ns, m[1] - 1, 0, { line_hl_group = m[2] })
  end
  local function part(name, text) local l = KL(name) ; return l ~= "" and (l .. " " .. text) or nil end
  local parts
  if r then
    parts = { part("check", "next"), part("next", "next"), part("refs", "open code"), part("explain", "ask Claude"), part("retry", "retry"), part("overview", "overview"), part("close", "close") }
  else
    local ck = keys.opts("quiz").choices
    parts = {
      q.type == "open" and part("answer", "answer") or ((ck and ck ~= "") and (ck:sub(1, 1) .. "-" .. ck:sub(-1) .. " pick") or nil),
      q.type ~= "open" and part("toggle_choice", "toggle choice under cursor") or nil,
      q.type ~= "open" and part("check", "check") or nil,
      part("dont_know", "don't know"), part("hint", "hint"), part("next", "skip"), part("prev", "back"), part("close", "close"),
    }
  end
  local footer = table.concat(vim.tbl_filter(function(x) return x end, parts), " · ")
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_set_config, M.win, { footer = " " .. footer .. " ", footer_pos = "center" })
    pcall(vim.api.nvim_win_set_cursor, M.win, { 1, 0 })
  end
end

--------------------------------------------------------------------------- grading
local function save_attempt(it, q, answer, r)
  local at = attempts()
  local prev = at[q.id] or { history = {} }
  local entry = { answer = answer, score = r.score, verdict = r.verdict, feedback = r.feedback or "", at = state.now() }
  local history = prev.history or {}
  history[#history + 1] = entry
  while #history > 10 do table.remove(history, 1) end
  at[q.id] = { quiz = it.quiz, qid = q.id, level = q.level, topic = q.topic, prompt = (q.prompt or ""):sub(1, 300), history = history, last = entry }
  state.save(core.project)
  core.changed()
end

local function score_choices(q, sel)
  local ans, n = {}, 0
  for _, a in ipairs(q.answer or {}) do ans[a + 1] = true ; n = n + 1 end
  local tp, fp, picked = 0, 0, {}
  for i in pairs(sel) do
    picked[#picked + 1] = i - 1
    if ans[i] then tp = tp + 1 else fp = fp + 1 end
  end
  table.sort(picked)
  if q.type == "single" then
    local ok = #picked == 1 and ans[picked[1] + 1] == true
    return { score = ok and 1 or 0, verdict = ok and "correct" or "wrong" }, picked
  end
  local exact = tp == n and fp == 0
  local score = math.max(0, (tp - fp) / math.max(n, 1))
  return { score = exact and 1 or score, verdict = exact and "correct" or (score > 0 and "partial" or "wrong") }, picked
end

function M.excerpts(q, quiz_id)
  local step = quiz_step(quiz_id)
  local out = {}
  for i, ref in ipairs(q.refs or {}) do
    if i > 4 then break end
    local content = git.show(core.project, step.head_ref, ref.path)
    if content then
      local lines = vim.split(content, "\n", { plain = true })
      local a, b = (ref.line or 1) - 25, (ref.endLine or ref.line or 1) + 25
      out[#out + 1] = ("%s lines %d-%d:\n%s"):format(ref.path, math.max(1, a), math.min(#lines, b), diff.numbered(lines, a, b))
    end
  end
  return table.concat(out, "\n\n"):sub(1, 40000)
end

local function grade_open(it, q, text)
  local s = M.s
  s.busy = true
  render()
  local prompt = table.concat({
    "You grade a developer's answer to a quiz question about their team's codebase. Be fair and precise: accept answers that are right in substance even if shorter or worded differently; penalise wrong facts; do not require details the question does not ask for.",
    "",
    ("Question (level %s, %s): %s"):format(q.level, LEVELS[q.level] or "", q.prompt),
    q.code and ("Code shown with the question:\n```\n" .. q.code .. "\n```") or "",
    "Reference answer: " .. (q.reference or ""),
    "Explanation: " .. (q.explanation or ""),
    "",
    "Relevant code from the repository:",
    M.excerpts(q, it.quiz),
    "",
    'Developer\'s answer:\n"""' .. text:sub(1, 6000) .. '"""',
    "",
    'Reply with only JSON: {"score": number from 0 to 1, "verdict": "correct" | "partial" | "wrong", "feedback": "2-4 sentences addressed to the developer: what was right, what was wrong or missing, with file:line when useful", "missing": ["short key points they missed"]}',
  }, "\n")
  claude.run(prompt, { json = true, tools = config.options.claude.grade_tools, use = "grade" }, function(err, res)
    if M.s ~= s or s.items[s.pos] ~= it then return end
    s.busy = false
    if err or type(res) ~= "table" then
      s.result = { verdict = "pending", self_grade = true, feedback = "Claude could not grade this answer (" .. (err or "unexpected reply") .. "). Compare with the reference answer and grade yourself." }
    else
      local score = math.max(0, math.min(1, tonumber(res.score) or 0))
      local verdict = (res.verdict == "correct" or res.verdict == "partial" or res.verdict == "wrong") and res.verdict
        or (score >= 0.8 and "correct" or score >= 0.4 and "partial" or "wrong")
      local missing = {}
      for _, m in ipairs(type(res.missing) == "table" and res.missing or {}) do missing[#missing + 1] = tostring(m) end
      s.result = { score = score, verdict = verdict, feedback = tostring(res.feedback or ""), missing = missing }
      save_attempt(it, q, text, s.result)
    end
    render()
  end)
end

function M.submit(dont_know)
  local s = M.s
  local it, q = cur()
  if not q or s.result or s.busy then return end
  if dont_know then
    s.result = { score = 0, verdict = "wrong", feedback = "" }
    save_attempt(it, q, q.type == "open" and "" or {}, s.result)
    return render()
  end
  if q.type == "open" then
    if s.text == "" then return M.answer() end
    if not config.options.ai.grade_open_answers then
      s.result = { verdict = "pending", self_grade = true, feedback = "Compare with the reference answer and grade yourself." }
      return render()
    end
    return grade_open(it, q, s.text)
  end
  if next(s.sel) == nil then return ui.notify("pick an answer first (a-f)") end
  local r, picked = score_choices(q, s.sel)
  s.result = r
  save_attempt(it, q, picked, r)
  render()
end

function M.self_grade(v)
  local s = M.s
  local it, q = cur()
  if not q or not (s.result and s.result.self_grade) then return end
  s.result = { score = v == "correct" and 1 or v == "partial" and 0.5 or 0, verdict = v, feedback = "Graded by you." }
  save_attempt(it, q, s.text, s.result)
  render()
end

function M.answer()
  local _, q = cur()
  if not q or q.type ~= "open" or M.s.result then return end
  ui.input({ title = "Your answer", text = M.s.text, height = 14 }, function(text)
    M.s.text = text
    if M.win and vim.api.nvim_win_is_valid(M.win) then vim.api.nvim_set_current_win(M.win) end
    M.submit(false)
  end)
end

--------------------------------------------------------------------------- navigation
local function reset()
  M.s.sel, M.s.text, M.s.result, M.s.busy = {}, "", nil, false
end

function M.go(delta)
  M.s.pos = math.max(1, math.min(#M.s.items + 1, M.s.pos + delta))
  reset()
  render()
end

function M.toggle_choice(i)
  local _, q = cur()
  if not q or not q.choices or M.s.result or i > #q.choices then return end
  if q.type == "multi" then M.s.sel[i] = (not M.s.sel[i]) or nil else M.s.sel = { [i] = true } end
  render()
end

function M.open_ref(i)
  local it, q = cur()
  if not q or not q.refs or not q.refs[i] then return end
  local ref = q.refs[i]
  local step = quiz_step(it.quiz)
  M.close()
  local review = require("reviewer.review")
  if core.step.id ~= step.id then
    if not require("reviewer").start_review(step.id) then return end
    step = core.step
  end
  local f = git.find_file(core.project, step, ref.path)
  if f then
    review.open(step, f, ref.line)
  else
    local dir, err = git.step_dir(core.project, step, true)
    if not dir then return ui.notify(err or "no folder", vim.log.levels.ERROR) end
    vim.api.nvim_set_current_win(review.main_win())
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. ref.path))
    pcall(vim.api.nvim_win_set_cursor, 0, { ref.line or 1, 0 })
    vim.cmd("normal! zz")
  end
  ui.notify("back to the quiz: :ReviewQuiz")
end

function M.ask(kind)
  local it, q = cur()
  if not q then return end
  local s = M.s
  local answered = s.result and s.result.verdict ~= "pending"
  local yours = q.type == "open" and s.text or table.concat(vim.tbl_map(function(i) return LETTERS:sub(i, i) end, vim.tbl_keys(s.sel)), ", ")
  local correct = q.choices and table.concat(vim.tbl_map(function(a) return LETTERS:sub(a + 1, a + 1) end, q.answer or {}), ", ") or "see reference"
  local parts = {
    claude.PROJECT_INTRO, "",
    ("The developer is taking a quiz about project %s (%s). Your working directory holds the code the question is about; you may read files."):format(core.project.name, title(it.quiz)),
    ("Question %s (level %s, %s, %s): %s"):format(q.id, q.level, LEVELS[q.level] or "", q.type, q.prompt),
    q.code and ("Code shown:\n```\n" .. q.code .. "\n```") or "",
  }
  if q.choices then
    local cl = {}
    for i, c in ipairs(q.choices) do cl[#cl + 1] = LETTERS:sub(i, i) .. ". " .. c end
    parts[#parts + 1] = "Choices:\n" .. table.concat(cl, "\n")
  end
  if answered then
    parts[#parts + 1] = ("Correct answer: %s\nReference: %s\nExplanation: %s\nThe developer answered: %s → %s%s"):format(correct, q.reference or "", q.explanation or "", yours ~= "" and yours or "(nothing)", s.result.verdict, s.result.feedback ~= "" and (". Grader feedback: " .. s.result.feedback) or "")
  else
    parts[#parts + 1] = "The developer has NOT answered yet" .. (yours ~= "" and (" (draft: " .. yours .. ")") or "") .. ". Give hints that guide their reasoning, but do not reveal the answer unless they explicitly ask for it.\n(For your reasoning only, the reference answer is: " .. (q.reference or "") .. ")"
  end
  parts[#parts + 1] = "\nRelevant code:\n" .. M.excerpts(q, it.quiz)
  local question_text = kind == "hint" and "Give me a hint for this question without revealing the answer."
    or (answered and s.result.verdict == "correct" and "Explain this answer in more depth, with the code."
      or "Explain why my answer is wrong or incomplete, and the right reasoning, with the code.")
  local step = quiz_step(it.quiz)
  -- run where the code is only for the current review (the hidden checkout must not move)
  local dir = step.id == core.step.id and git.step_dir(core.project, step, true) or nil
  require("reviewer.ask").run({ kind = "quiz", quiz = it.quiz, qid = q.id, question = question_text, title = title(it.quiz) .. " · " .. q.id }, table.concat(parts, "\n"), dir)
end

function M.overview(quiz_id)
  quiz_id = quiz_id or (M.s and M.s.quiz)
  local q = load()[quiz_id]
  if not q then return end
  local at = attempts()
  local lines = { "# " .. title(quiz_id), "" }
  local st = M.stats(quiz_id)
  lines[#lines + 1] = ("%d/%d answered · %d right · %d partly · %d wrong"):format(st.answered, st.total, st.ok, st.part, st.bad)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Level | | Answered | Right | Partly | Wrong |"
  lines[#lines + 1] = "|---|---|---|---|---|---|"
  for l = 1, 5 do
    local n, a, ok, part, bad = 0, 0, 0, 0, 0
    for _, x in ipairs(q.questions) do
      if x.level == l then
        n = n + 1
        local t = at[x.id]
        if t and t.last then
          a = a + 1
          if t.last.verdict == "correct" then ok = ok + 1 elseif t.last.verdict == "partial" then part = part + 1 else bad = bad + 1 end
        end
      end
    end
    if n > 0 then lines[#lines + 1] = ("| %d | %s | %d/%d | %d | %d | %d |"):format(l, LEVELS[l], a, n, ok, part, bad) end
  end
  ui.show("Quiz overview", lines, { width = 90, height = 16 })
end

--------------------------------------------------------------------------- window
function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then pcall(vim.api.nvim_win_close, M.win, true) end
  M.win, M.buf = nil, nil
end

local function show()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_set_current_win(M.win)
    return render()
  end
  M.buf, M.win = ui.float({ title = "Review quiz", filetype = "markdown", width = TW() + 8 })
  local buf = M.buf
  local k = keys.opts("quiz")
  local function map(lhs, fn, desc) keys.map(buf, "n", lhs, fn, desc or "quiz") end
  local ck = k.choices or ""
  for i = 1, #ck do map(ck:sub(i, i), function() M.toggle_choice(i) end, "pick choice " .. i) end
  map(k.toggle_choice, function()
    local i = M.choice_at and M.choice_at[vim.api.nvim_win_get_cursor(0)[1]]
    if i then M.toggle_choice(i) end
  end, "toggle the choice under the cursor")
  map(k.check, function() if M.s.result and not M.s.result.self_grade then M.go(1) else M.submit(false) end end, "check / next")
  map(k.next, function() M.go(1) end, "next question")
  map(k.prev, function() M.go(-1) end, "previous question")
  map(k.dont_know, function() M.submit(true) end, "don't know")
  map(k.answer, function() M.answer() end, "write an answer")
  map(k.retry, function() reset() ; render() end, "retry")
  map(k.hint, function() M.ask("hint") end, "hint")
  map(k.explain, function() M.ask("explain") end, "ask Claude why")
  map(k.overview, function() M.overview() end, "results by level")
  map(k.self_correct, function() M.self_grade("correct") end, "I had it")
  map(k.self_partial, function() M.self_grade("partial") end, "partly")
  map(k.self_wrong, function() M.self_grade("wrong") end, "I missed it")
  for i, lhs in ipairs(keys.list(k.refs)) do map(lhs, function() M.open_ref(i) end, "open code " .. i) end
  map(k.close, function() M.close() end, "close")
  render()
end

local function start(quiz_id, mode)
  local items = {}
  local at = attempts()
  local ids = quiz_id == "mistakes" and M.ids() or { quiz_id }
  for _, qid in ipairs(ids) do
    local quiz = load()[qid]
    for _, x in ipairs(quiz and quiz.questions or {}) do
      local a = at[x.id]
      local wrong = a and a.last and a.last.verdict ~= "correct"
      if mode ~= "mistakes" or wrong then items[#items + 1] = { quiz = qid, id = x.id } end
    end
  end
  M.s = { quiz = quiz_id, items = items, pos = 1, mode = mode }
  reset()
  if mode == "continue" then
    for i, x in ipairs(items) do
      if not at[x.id] then M.s.pos = i break end
    end
  end
  show()
end

-- Open a specific question (from the progress view).
function M.open_question(quiz_id, qid)
  local quiz = load()[quiz_id]
  if not quiz then return end
  start(quiz_id, "all")
  for i, x in ipairs(M.s.items) do if x.id == qid then M.s.pos = i end end
  render()
end

-- :ReviewQuiz [id|N|final|mistakes]
function M.open(arg)
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  load()
  if not arg or arg == "" then
    if M.s and M.s.quiz == core.step.id and M.s.items[M.s.pos] then return show() end
    arg = core.step.id
  end
  if arg == "list" then
    local items = {}
    for _, id in ipairs(M.ids()) do
      local s = M.stats(id)
      items[#items + 1] = { id = id, label = ("%s  (%d/%d answered, %d right)"):format(title(id), s.answered, s.total, s.ok) }
    end
    items[#items + 1] = { id = "mistakes", label = "Retry all my mistakes" }
    if #items == 1 then return ui.notify("no quiz found in " .. core.project.quiz_dir, vim.log.levels.WARN) end
    return vim.ui.select(items, { prompt = "Quiz", format_item = function(i) return i.label end }, function(c)
      if c then vim.schedule(function() M.open(c.id) end) end
    end)
  end
  if arg == "mistakes" then return start("mistakes", "mistakes") end
  if not load()[arg] then
    if vim.uv.fs_stat(core.quiz_file(arg)) then
      return ui.notify("could not read " .. core.quiz_file(arg), vim.log.levels.ERROR)
    end
    return require("reviewer.prepare").quiz_or_write(arg, function() M.reload() ; M.open(arg) end)
  end
  if M.s and M.s.quiz == arg and M.s.items[M.s.pos] then return show() end
  local s = M.stats(arg)
  local choices = {}
  if s.answered > 0 and s.answered < s.total then choices[#choices + 1] = { mode = "continue", label = ("Continue where I stopped (%d/%d answered)"):format(s.answered, s.total) } end
  choices[#choices + 1] = { mode = "all", label = s.answered > 0 and "Go through all questions again" or ("Start the quiz (%d questions)"):format(s.total) }
  if s.part + s.bad > 0 then choices[#choices + 1] = { mode = "mistakes", label = ("Retry my %d mistakes"):format(s.part + s.bad) } end
  choices[#choices + 1] = { mode = "overview", label = "See my results by level" }
  vim.ui.select(choices, { prompt = title(arg), format_item = function(c) return c.label end }, function(c)
    if not c then return end
    vim.schedule(function()
      if c.mode == "overview" then M.overview(arg) else start(arg, c.mode) end
    end)
  end)
end

return M
