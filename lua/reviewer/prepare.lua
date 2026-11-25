-- :ReviewPrepare: prepares a whole step in the background, in three stages:
--   1. overview  one call that reads the step as a whole (summary, flows, role of each file)
--   2. comments  Claude's comments on every file, a few files per call, with the overview as context
--   3. quiz      a quiz on the step, checked locally (refs must exist, code snippets must match)
-- Resumable: files already commented for the same diff are skipped.
local config = require("reviewer.config")
local core = require("reviewer.core")
local state = require("reviewer.state")
local git = require("reviewer.git")
local claude = require("reviewer.claude")
local explain = require("reviewer.explain")
local ui = require("reviewer.ui")

local M = { jobs = {} } -- key ("1".."n" or "final") -> job

local function tag(key) return "prepare:" .. core.project.name .. ":" .. key end

function M.status(key)
  local j = M.jobs[key]
  if not j or j.finished then return nil end
  local s = j.stage == "comments" and ("comments %d/%d"):format(j.done, j.total) or (j.stage .. "…")
  return ("preparing: %s · $%.2f"):format(s, j.cost)
end

local function finish(job, msg, level)
  if job.finished then return end
  job.finished = true
  local errs = #job.errors > 0 and (" · %d problem(s): %s"):format(#job.errors, table.concat(job.errors, "; "):sub(1, 300)) or ""
  ui.notify(("%s%s · cost $%.2f"):format(msg, errs, job.cost), level or (#job.errors > 0 and vim.log.levels.WARN or nil))
  core.changed()
  if job.on_done then job.on_done() end
end

local function reviewable_files(step)
  local list = {}
  for _, f in ipairs(core.ordered(step, { hide_generated = true, order = "reading" })) do
    if not f.binary then list[#list + 1] = f end
  end
  return list
end

-- Diffs with a little context, capped per file and in total.
local function diff_excerpt(step, files, budget)
  local out, used = {}, 0
  for _, f in ipairs(files) do
    local paths = f.old and { f.old, f.path } or { f.path }
    local d = git.run(vim.list_extend({ "diff", "-M", "-U3", "--no-color", step.base_ref, step.head_ref, "--" }, paths), core.project.root) or ""
    if #d > 8000 then d = d:sub(1, 8000) .. "\n…(diff truncated; read the file for the rest)\n" end
    if used + #d > budget then
      out[#out + 1] = ("(diff of %s left out for size; read the file)"):format(f.path)
    else
      out[#out + 1] = d
      used = used + #d
    end
  end
  return table.concat(out, "\n")
end

local function file_list(files)
  local l = {}
  for _, f in ipairs(files) do l[#l + 1] = ("%s %s +%d -%d"):format(f.status, f.path, f.add, f.del) end
  return table.concat(l, "\n")
end

------------------------------------------------------------------------ overview
local function run_overview(job, step, next_stage)
  job.stage = "overview"
  core.changed()
  local files = reviewable_files(step)
  local commits = {}
  for _, c in ipairs(git.commits(core.project, step)) do commits[#commits + 1] = c.hash .. " " .. c.subject end
  local generated = #core.files(step) - #files
  local prompt = table.concat({
    "You are preparing the review of one step of a stack of branches, for a developer who will then read every changed file and answer a quiz about it.",
    "",
    explain.step_context(core.project, step, 0),
    "",
    "Commits in this step:", table.concat(commits, "\n"),
    "",
    ("Changed files to review (%d; %d generated files are left out):"):format(#files, generated),
    file_list(files),
    "",
    "Diffs (with 3 lines of context; some are truncated, read the files when you need more):",
    diff_excerpt(step, files, 200000),
    "",
    "Reply with only JSON in this shape:",
    '{"summary": "one or two paragraphs: what this step adds or changes as a whole, and how the work is split between the layers (database, shared code, backend, frontend, tests)",',
    ' "flows": [{"name": "short name", "description": "2-4 sentences: the path through the code from start to end, naming the files involved"}],',
    ' "concepts": ["key models, rules or ideas a reviewer must understand"],',
    ' "risks": ["things a reviewer should check carefully, with path:line"],',
    ' "files": [{"path": "exact path from the list above", "role": "one sentence: what this file does in this step"}]}',
    "Give one entry in \"files\" for every changed file listed above. Only state what the code shows.",
  }, "\n")
  claude.run(prompt, { json = true, tools = config.options.claude.prepare_tools, cwd = job.dir, tag = job.tag, use = "overview" }, function(err, res, meta)
    job.cost = job.cost + (meta and meta.cost or 0)
    if err or type(res) ~= "table" or not res.summary then
      table.insert(job.errors, "overview: " .. (err or "unexpected reply"))
      return finish(job, "step " .. step.id .. ": the overview could not be written")
    end
    local roles = {}
    for _, fr in ipairs(type(res.files) == "table" and res.files or {}) do
      if type(fr) == "table" and fr.path then roles[#roles + 1] = { path = tostring(fr.path), role = tostring(fr.role or "") } end
    end
    local flows = {}
    for _, fl in ipairs(type(res.flows) == "table" and res.flows or {}) do
      if type(fl) == "table" then flows[#flows + 1] = { name = tostring(fl.name or ""), description = tostring(fl.description or "") } end
    end
    local function strings(t) local o = {} for _, x in ipairs(type(t) == "table" and t or {}) do o[#o + 1] = tostring(x) end return o end
    local ex = state.explain(core.project)
    ex.steps = ex.steps or {}
    ex.steps[step.id] = {
      hash = explain.step_hash(core.project, step), summary = tostring(res.summary), flows = flows,
      concepts = strings(res.concepts), risks = strings(res.risks), files = roles,
      at = state.now(), cost = meta and meta.cost or 0,
    }
    state.save(core.project, "explain")
    core.changed()
    next_stage()
  end)
end

------------------------------------------------------------------------ comments
local function run_comments(job, step, next_stage)
  job.stage = "comments"
  local todo = {}
  for _, f in ipairs(reviewable_files(step)) do
    if not job.paths or job.paths[f.path] then
      local ctx = core.make_ctx(step, f)
      if ctx and (job.force or not explain.get(ctx)) then todo[#todo + 1] = ctx end
    end
  end
  job.total, job.done = #todo, 0
  core.changed()
  if #todo == 0 then return next_stage() end
  -- batches by size
  local batches, cur, size = {}, {}, 0
  local maxc, maxf = config.options.claude.batch_chars or 60000, config.options.claude.batch_files or 6
  for _, ctx in ipairs(todo) do
    local section = explain.file_section(ctx)
    if #cur > 0 and (size + #section > maxc or #cur >= maxf) then
      batches[#batches + 1] = cur
      cur, size = {}, 0
    end
    cur[#cur + 1] = { ctx = ctx, section = section }
    size = size + #section
  end
  if #cur > 0 then batches[#batches + 1] = cur end
  local pending = #batches
  local context = explain.step_context(core.project, step)
  for _, batch in ipairs(batches) do
    local sections, by_path = {}, {}
    for _, b in ipairs(batch) do
      sections[#sections + 1] = b.section
      by_path[b.ctx.file.path] = b.ctx
      explain.status[explain.key(b.ctx)] = "pending"
    end
    local prompt = table.concat({
      "You explain code changes to a developer who is reviewing their team's code and wants to understand it deeply.",
      "",
      context,
      "",
      explain.LISTING_HELP,
      "",
      table.concat(sections, "\n\n"),
      "",
      "Reply with only JSON in this shape, with one entry per file above:",
      '{"files": [{"path": "exact path", "summary": "2-4 sentences: what this file is for in the project and who uses it", "changes": "2-5 sentences: what changed in this step, why it matters, what to keep in mind", "comments": [{"block": "B1", "line": 42, "text": "..."}]}]}',
      "Block ids are per file.",
      explain.COMMENT_RULES,
      "Put identifiers in backticks.",
    }, "\n")
    claude.run(prompt, { json = true, tools = config.options.claude.prepare_tools, cwd = job.dir, tag = job.tag, use = "comments" }, function(err, res, meta)
      job.cost = job.cost + (meta and meta.cost or 0)
      local got = {}
      if not err and type(res) == "table" and type(res.files) == "table" then
        for _, entry in ipairs(res.files) do
          local ctx = type(entry) == "table" and by_path[entry.path]
          if ctx and type(entry.comments) == "table" then
            explain.store(ctx, entry)
            got[entry.path] = true
          end
        end
      end
      for path, ctx in pairs(by_path) do
        explain.status[explain.key(ctx)] = nil
        if got[path] then job.done = job.done + 1
        elseif err ~= "cancelled" then table.insert(job.errors, path .. (err and (": " .. err) or ": missing from the reply")) end
      end
      core.changed()
      pending = pending - 1
      if pending == 0 and not job.finished then
        if err == "cancelled" then return finish(job, "step " .. step.id .. ": preparation stopped") end
        next_stage()
      end
    end)
  end
end

------------------------------------------------------------------------ quiz
-- Keeps only questions whose refs exist at `ref` and whose code snippet is in a ref file.
function M.validate(questions, ref, prefix)
  local cache, kept, dropped = {}, {}, {}
  local function lines_of(path)
    if cache[path] == nil then
      local c = git.show(core.project, ref, path)
      cache[path] = c and vim.split(c, "\n", { plain = true }) or false
    end
    return cache[path]
  end
  local types = { single = true, multi = true, open = true }
  for _, q in ipairs(type(questions) == "table" and questions or {}) do
    local why
    if type(q) ~= "table" or type(q.prompt) ~= "string" or not types[q.type] then why = "bad shape"
    else
      q.level = tonumber(q.level) or 3
      if q.type ~= "open" then
        local n = type(q.choices) == "table" and #q.choices or 0
        if n < 2 or type(q.answer) ~= "table" or #q.answer == 0 then why = "no choices or answer" end
        for _, a in ipairs(type(q.answer) == "table" and q.answer or {}) do
          if type(a) ~= "number" or a < 0 or a >= n then why = "answer out of range" end
        end
        if not why and q.type == "single" and #q.answer ~= 1 then why = "single with several answers" end
      end
      local refs = {}
      for _, r in ipairs(type(q.refs) == "table" and q.refs or {}) do
        local ls = type(r) == "table" and r.path and lines_of(r.path)
        if ls and tonumber(r.line) and r.line >= 1 and r.line <= #ls then
          r.endLine = tonumber(r.endLine) and math.min(math.max(r.endLine, r.line), #ls) or nil
          refs[#refs + 1] = r
        end
      end
      if not why and #refs == 0 then why = "no valid file:line reference" end
      q.refs = refs
      if not why and type(q.code) == "string" and q.code ~= "" then
        for _, cl in ipairs(vim.split(q.code, "\n")) do
          local t = vim.trim(cl)
          if t ~= "" and t ~= "..." and t ~= "…" then
            local found = false
            for _, r in ipairs(refs) do
              for _, l in ipairs(lines_of(r.path)) do
                if vim.trim(l) == t then found = true break end
              end
              if found then break end
            end
            if not found then why = "code snippet not found in the referenced files" break end
          end
        end
      end
    end
    if why then dropped[#dropped + 1] = why else kept[#kept + 1] = q end
  end
  for i, q in ipairs(kept) do q.id = ("%s%02d"):format(prefix, i) end
  return kept, dropped
end

local QUIZ_RULES = [[
QUIZ CONTENT: %d questions, ordered from the biggest picture to the smallest, in 5 levels:
- level 1 "Architecture": what the work adds as a whole, how layers split it, data model changes.
- level 2 "Flows & design": end-to-end flows, why things are designed this way, permissions, error handling.
- level 3 "Files & responsibilities": which file does what, where logic lives, which file to change for X.
- level 4 "Implementation": how specific functions/components work, inputs/outputs, edge cases, status codes.
- level 5 "Line-level details": what a specific line or snippet does, what breaks if it changes, exact values.
Spread them roughly 13%%, 20%%, 23%%, 23%%, 21%% across levels 1 to 5.
Mix types: about 55%% "single" (exactly one correct choice out of 4), 15%% "multi" (several correct out of 4-6), 30%% "open" (free-text answer graded later against your reference). Wrong choices must be plausible. Include a short "code" snippet (copied exactly from the file, at most 15 lines) when a question is about specific code. Do not reveal the answer in the prompt.

ACCURACY IS CRITICAL. Read the files with your tools before writing questions about them. Every fact must come from code you read. Each question needs at least one ref with the exact path and line numbers in the files as they are in your working directory; count lines carefully (use Grep with line numbers). Questions whose references or snippets do not match the files are thrown away automatically. If unsure, do not ask it.

Reply with only JSON:
{"questions": [{"level": 1, "topic": "short topic", "type": "single", "prompt": "...", "code": "optional", "codeLang": "typescript", "choices": ["..."], "answer": [0], "reference": "model answer for open questions (2-6 sentences); one-line summary for choice questions", "explanation": "why, 2-5 sentences", "refs": [{"path": "src/...", "line": 12, "endLine": 20}]}]}
For "open" questions, omit choices and answer. Write in English; keep identifiers and UI strings exactly as in the code.]]

local function write_quiz(id, title, ref, questions)
  local path = core.project.quiz_dir .. "/quiz-" .. id .. ".json"
  vim.fn.mkdir(core.project.quiz_dir, "p")
  local fh = io.open(path, "w")
  if not fh then return nil end
  fh:write(vim.json.encode({ id = id, title = title, ref = ref, generated_by = "reviewer", at = state.now(), questions = questions }))
  fh:close()
  require("reviewer.quiz").reload()
  return path
end

local function quiz_exists(id) return vim.uv.fs_stat(core.project.quiz_dir .. "/quiz-" .. id .. ".json") ~= nil end

local function run_quiz(job, step, next_stage)
  local qid = "step" .. step.id
  if quiz_exists(qid) and not job.force_quiz then
    table.insert(job.notes, "kept the existing quiz (use :ReviewPrepare! " .. step.id .. " quiz to write a new one)")
    return next_stage()
  end
  job.stage = "quiz"
  core.changed()
  local files = reviewable_files(step)
  local n = math.max(25, math.min(65, 20 + math.floor(#files * 0.5)))
  local prompt = table.concat({
    "You write a review quiz about one step of a stack of branches. The developer takes it after reading every changed file, to check they understand the code: architecture, flows, which file does what, and implementation details.",
    "",
    explain.step_context(core.project, step),
    "",
    "Changed files in this step:", file_list(files),
    "",
    QUIZ_RULES:format(n),
  }, "\n")
  claude.run(prompt, { json = true, tools = config.options.claude.prepare_tools, cwd = job.dir, tag = job.tag, use = "quiz" }, function(err, res, meta)
    job.cost = job.cost + (meta and meta.cost or 0)
    if err or type(res) ~= "table" then
      table.insert(job.errors, "quiz: " .. (err or "unexpected reply"))
      return next_stage()
    end
    local kept, dropped = M.validate(res.questions, step.head_ref, "s" .. step.id .. "-q")
    if #kept == 0 then
      table.insert(job.errors, "quiz: no question passed the checks")
    else
      write_quiz(qid, step.label, step.head_ref, kept)
      table.insert(job.notes, ("quiz: %d questions kept, %d dropped by the checks"):format(#kept, #dropped))
    end
    next_stage()
  end)
end

------------------------------------------------------------------------ entry points
-- opts: { force = bool, stages = { overview = bool, comments = bool, quiz = bool }, paths = { [path] = true } }
function M.step(step, opts, on_done)
  opts = opts or {}
  local key = step.id
  if M.jobs[key] and not M.jobs[key].finished then return ui.notify("step " .. key .. " is already being prepared") end
  local dir, derr = git.step_dir(core.project, step, true)
  if not dir then return ui.notify(derr or "no folder for this step", vim.log.levels.ERROR) end
  local stages = opts.stages or { overview = true, comments = true, quiz = true }
  local job = { tag = tag(key), stage = "starting", done = 0, total = 0, cost = 0, errors = {}, notes = {}, dir = dir,
    force = opts.force and stages.comments, force_quiz = opts.force, paths = opts.paths, on_done = on_done }
  M.jobs[key] = job
  ui.notify("preparing step " .. step.id .. " (" .. step.label .. ") in the background. :ReviewPrepare stop cancels it.")
  local function done()
    finish(job, ("step %s prepared%s"):format(step.id, #job.notes > 0 and (" · " .. table.concat(job.notes, " · ")) or ""))
  end
  local function quiz() if stages.quiz then run_quiz(job, step, done) else done() end end
  local function comments() if stages.comments then run_comments(job, step, quiz) else quiz() end end
  local need_overview = stages.overview and (opts.force and not opts.paths or not explain.overview(core.project, step))
  -- comments and quiz rely on the overview, so write it first when it is missing
  if need_overview or ((stages.comments or stages.quiz) and not explain.overview(core.project, step)) then
    run_overview(job, step, comments)
  else
    comments()
  end
end

function M.final(opts, on_done)
  opts = opts or {}
  if M.jobs.final and not M.jobs.final.finished then return ui.notify("the final quiz is already being prepared") end
  if quiz_exists("final") and not opts.force then return ui.notify("a final quiz already exists (use :ReviewPrepare! final to write a new one)") end
  local last = core.project.steps[#core.project.steps]
  local dir, derr = git.step_dir(core.project, last, true)
  if not dir then return ui.notify(derr or "no folder for the last step", vim.log.levels.ERROR) end
  local overviews, missing = {}, {}
  for _, s in ipairs(core.project.steps) do
    local o = explain.overview(core.project, s)
    if o then overviews[#overviews + 1] = ("Step %s \"%s\":\n%s"):format(s.id, s.label, o.summary)
    else missing[#missing + 1] = s.id end
  end
  local job = { tag = tag("final"), stage = "quiz", done = 0, total = 0, cost = 0, errors = {}, notes = {}, dir = dir, on_done = on_done }
  M.jobs.final = job
  core.changed()
  if #missing > 0 then table.insert(job.notes, "steps without an overview: " .. table.concat(missing, ", ")) end
  local p = core.project
  local prompt = table.concat({
    "You write the FINAL review quiz on a whole stack of branches. The developer already took one quiz per step, so focus on the system as a whole and on how the steps connect: cross-cutting flows, where things live in the final code, which step introduced what.",
    "",
    ("Project: %s. Stack: %s → %s. Your working directory holds the final code (%s); you may read and search any file."):format(p.name, p.base, table.concat(p.stack, " → "), last.head_ref),
    "",
    "Overviews of each step (written earlier):",
    table.concat(overviews, "\n\n"),
    "",
    QUIZ_RULES:format(80),
  }, "\n")
  ui.notify("writing the final quiz in the background…")
  claude.run(prompt, { json = true, tools = config.options.claude.prepare_tools, cwd = dir, tag = job.tag, use = "final" }, function(err, res, meta)
    job.cost = job.cost + (meta and meta.cost or 0)
    if err or type(res) ~= "table" then
      table.insert(job.errors, "final quiz: " .. (err or "unexpected reply"))
    else
      local kept, dropped = M.validate(res.questions, last.head_ref, "f-q")
      if #kept > 0 then
        write_quiz("final", "Final quiz: the whole stack", last.head_ref, kept)
        table.insert(job.notes, ("%d questions kept, %d dropped by the checks"):format(#kept, #dropped))
      else
        table.insert(job.errors, "final quiz: no question passed the checks")
      end
    end
    finish(job, "final quiz")
  end)
end

-- :ReviewPrepare[!] [n|final|all|stop] [overview|comments|quiz]
function M.command(args, bang)
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local target, stage = args[1], args[2]
  if target == "stop" then
    for key, j in pairs(M.jobs) do
      if not j.finished then claude.cancel(j.tag) ; j.finished = true ; j.errors = {} ; ui.notify("stopped preparing " .. key) end
    end
    return core.changed()
  end
  local stages
  if stage then
    if not ({ overview = true, comments = true, quiz = true })[stage] then return ui.notify("stage must be overview, comments or quiz", vim.log.levels.WARN) end
    stages = { [stage] = true }
  end
  if target == "final" then return M.final({ force = bang }) end
  if target == "all" then
    local i = 0
    local function next_step()
      i = i + 1
      local s = core.project.steps[i]
      if s then M.step(s, { force = bang, stages = stages }, next_step)
      elseif not stages or stages.quiz then M.final({ force = bang }) end
    end
    return next_step()
  end
  local step = target and core.project.steps[tonumber(target) or 0] or core.step
  if not step then return ui.notify("no step " .. tostring(target), vim.log.levels.WARN) end
  M.step(step, { force = bang, stages = stages })
end

-- Comment only some files (from a panel group or folder).
function M.paths(step, paths)
  local set = {}
  for _, p in ipairs(paths) do set[p] = true end
  M.step(step, { stages = { comments = true }, paths = set })
end

-- What is already prepared for a step (cheap: counts saved entries, does not diff every file).
function M.step_state(step)
  local commented = 0
  local prefix = step.id .. "|"
  for k in pairs(state.explain(core.project).files) do
    if k:sub(1, #prefix) == prefix then commented = commented + 1 end
  end
  local _, total = core.reviewable(step)
  return {
    overview = explain.overview(core.project, step) ~= nil,
    commented = math.min(commented, total), total = total,
    quiz = quiz_exists("step" .. step.id),
    running = M.jobs[step.id] ~= nil and not M.jobs[step.id].finished,
  }
end

function M.describe(step)
  local s = M.step_state(step)
  return ("overview %s · comments %d/%d · quiz %s"):format(s.overview and "ready" or "missing", s.commented, s.total, s.quiz and "ready" or "missing"), s
end

-- Called by :Review, following ai.on_start.
function M.offer_on_start()
  local mode = config.options.ai.on_start
  if mode == "never" or not core.project then return end
  local step = core.step
  local desc, s = M.describe(step)
  local complete = s.overview and s.commented >= s.total and s.quiz
  if mode == "all" then return M.command({ "all" }, false) end
  if complete then return ui.notify(("step %s is already prepared (%s)"):format(step.id, desc)) end
  if mode == "step" then return M.step(step) end
  local choices = {
    { id = "step", label = ("Prepare step %s: overview, comments on every file, quiz"):format(step.id) },
    { id = "overview", label = ("Only the overview of step %s (one call)"):format(step.id) },
    { id = "all", label = "Prepare every step, then the final quiz (long)" },
    { id = "no", label = "Not now (use the actions at the top of the panel)" },
  }
  vim.ui.select(choices, {
    prompt = ("Run Claude on step %s (%s)? Now: %s"):format(step.id, step.label, desc),
    format_item = function(c) return c.label end,
  }, function(c)
    if not c or c.id == "no" then return end
    vim.schedule(function()
      if c.id == "step" then M.step(step)
      elseif c.id == "overview" then M.overview_then_show(step)
      elseif c.id == "all" then M.command({ "all" }, false) end
    end)
  end)
end

-- Show the overview, writing it first if needed.
function M.overview_then_show(step)
  step = step or core.step
  if explain.overview(core.project, step) then return M.show_overview(step) end
  M.step(step, { stages = { overview = true } }, function()
    if explain.overview(core.project, step) then M.show_overview(step) end
  end)
end

-- Take a quiz; offer to write it when it does not exist yet.
function M.quiz_or_write(quiz_id, on_ready)
  if quiz_exists(quiz_id) then return on_ready() end
  if not config.options.ai.offer_missing_quiz then return ui.notify("no quiz " .. quiz_id .. " yet: :ReviewPrepare " .. (quiz_id == "final" and "final" or quiz_id:gsub("step", "") .. " quiz")) end
  local is_final = quiz_id == "final"
  local step = not is_final and core.project.steps[tonumber(quiz_id:match("%d+"))] or nil
  vim.ui.select({ "Yes, write it now", "No" }, { prompt = ("There is no %s yet. Have Claude write it?"):format(is_final and "final quiz" or ("quiz for step " .. step.id)) }, function(c)
    if not (c and c:match("^Yes")) then return end
    vim.schedule(function()
      local function ready() if quiz_exists(quiz_id) then on_ready() end end
      if is_final then M.final({}, ready) else M.step(step, { stages = { quiz = true } }, ready) end
    end)
  end)
end

-- The step overview in a float.
function M.show_overview(step)
  step = step or core.step
  local o = explain.overview(core.project, step)
  if not o then return ui.notify("no overview for step " .. step.id .. " yet: :ReviewPrepare " .. step.id) end
  local lines = { ("# Step %s: %s"):format(step.id, step.label), "", ("_%s → %s · written %s_"):format(step.base_branch, step.branch, ui.fmt_date(o.at)), "" }
  vim.list_extend(lines, ui.wrap(o.summary, 96))
  if #o.flows > 0 then
    vim.list_extend(lines, { "", "## Main flows", "" })
    for _, fl in ipairs(o.flows) do
      vim.list_extend(lines, ui.wrap("- **" .. fl.name .. "**: " .. fl.description, 96))
    end
  end
  if #o.concepts > 0 then
    vim.list_extend(lines, { "", "## Key concepts", "" })
    for _, c in ipairs(o.concepts) do vim.list_extend(lines, ui.wrap("- " .. c, 96)) end
  end
  if #o.risks > 0 then
    vim.list_extend(lines, { "", "## To check carefully", "" })
    for _, r in ipairs(o.risks) do vim.list_extend(lines, ui.wrap("- " .. r, 96)) end
  end
  if #o.files > 0 then
    vim.list_extend(lines, { "", "## Files", "" })
    for _, fr in ipairs(o.files) do vim.list_extend(lines, ui.wrap("- `" .. fr.path .. "`: " .. fr.role, 96)) end
  end
  ui.show("Step overview", lines, { width = 104 })
end

return M
