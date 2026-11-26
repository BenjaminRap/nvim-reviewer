-- Claude's comments on a file: a summary, what changed, and a comment per change block.
-- Written once per file and saved; written again only if the diff changes or on request.
local config = require("reviewer.config")
local state = require("reviewer.state")
local claude = require("reviewer.claude")
local diff = require("reviewer.diff")
local git = require("reviewer.git")
local ui = require("reviewer.ui")

local M = { status = {} } -- key -> "pending" | "error: ..."

local STATUS = { A = "Added", M = "Modified", D = "Deleted", R = "Renamed" }
M.STATUS = STATUS

function M.key(ctx) return ctx.step.id .. "|" .. ctx.file.path end

function M.get(ctx)
  local e = state.explain(ctx.project).files[M.key(ctx)]
  if e and e.hash == ctx.hash then return e end
  return nil
end

function M.stale(ctx)
  local e = state.explain(ctx.project).files[M.key(ctx)]
  return e ~= nil and e.hash ~= ctx.hash
end

-- Step overview (written by :Review prepare), if there is one for the current diff.
function M.overview(project, step)
  local o = (state.explain(project).steps or {})[step.id]
  if o and o.hash == M.step_hash(project, step) then return o end
end

function M.step_hash(project, step)
  if not step._hash then
    step._hash = (git.rev(project, step.base_ref) or "") .. ".." .. (git.rev(project, step.head_ref) or "")
  end
  return step._hash
end

-- Shared context: project, step, and the overview when there is one.
function M.step_context(project, step, max_roles)
  local lines = {
    ("Repository: %s. The review covers the changes of branch %s compared with %s (%s..%s)."):format(project.name, step.branch, step.base_branch, step.base_ref, step.head_ref),
    "Your working directory holds the code at the head of the reviewed branch: you may open, search and read any file to understand how the code is used, but do not modify anything.",
  }
  local o = M.overview(project, step)
  if o then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Overview of all the changes (written earlier):"
    lines[#lines + 1] = o.summary or ""
    if o.flows and #o.flows > 0 then
      lines[#lines + 1] = "Main flows:"
      for _, fl in ipairs(o.flows) do lines[#lines + 1] = "- " .. (fl.name or "") .. ": " .. (fl.description or "") end
    end
    if o.files and #o.files > 0 and max_roles ~= 0 then
      lines[#lines + 1] = "Role of each changed file:"
      for i, fr in ipairs(o.files) do
        if max_roles and i > max_roles then break end
        lines[#lines + 1] = "- " .. (fr.path or "") .. ": " .. (fr.role or "")
      end
    end
  end
  return table.concat(lines, "\n")
end

-- Header + listing for one file (also used for batches).
function M.file_section(ctx)
  local f = ctx.file
  local commits = {}
  for _, c in ipairs(git.commits(ctx.project, ctx.step, f.path)) do commits[#commits + 1] = c.subject end
  return table.concat({
    ("=== FILE %s (%s%s, +%d −%d)"):format(f.path, STATUS[f.status] or f.status, f.old and (" from " .. f.old) or "", f.add, f.del),
    "Commits touching it: " .. table.concat(commits, " | "):sub(1, 1000),
    diff.listing(ctx.lines, ctx.hunks, 150000),
  }, "\n")
end

M.LISTING_HELP = "Each file is shown whole. Each line shows its new line number, then \"+\" for an added line, \"-\" for a removed line (with its old number), or a space for an unchanged line. Every run of changed lines is a block, introduced by \"### B<n>\"."

M.COMMENT_RULES = table.concat({
  "Rules for comments:",
  "- Comment every block that is not trivial; group tiny related blocks (imports, renames) into one comment on the first of them.",
  "- For a large block (more than about 25 lines, for example a new file), add one comment at the start of each logical section (function, component, route handler, type, test case), with \"line\" set to that section's first new line number. Otherwise \"line\" may be omitted.",
  "- Each comment: 1-4 sentences in plain English saying what the code does, how, and why; point out anything worth double-checking (edge cases, security, error handling). When it helps, say which other file uses this code or is used by it (path:line), after checking it with your tools.",
  "- Only state what the code shows. Never invent behaviour. At most 45 comments per file.",
}, "\n")

-- Save Claude's reply for one file.
function M.store(ctx, res)
  local comments = {}
  for _, c in ipairs(type(res.comments) == "table" and res.comments or {}) do
    if type(c) == "table" and c.text and c.text ~= "" then
      comments[#comments + 1] = { block = tostring(c.block or ""), line = tonumber(c.line), text = tostring(c.text) }
    end
  end
  state.explain(ctx.project).files[M.key(ctx)] = {
    hash = ctx.hash, step = ctx.step.id, path = ctx.file.path,
    summary = tostring(res.summary or ""), changes = tostring(res.changes or ""),
    comments = comments, at = state.now(),
  }
  state.save(ctx.project, "explain")
end

local function prompt(ctx)
  return table.concat({
    "You explain code changes to a developer who is reviewing their team's code and wants to understand it deeply.",
    "",
    M.step_context(ctx.project, ctx.step, 80),
    "",
    M.LISTING_HELP,
    "",
    M.file_section(ctx),
    "",
    "Reply with only JSON in this shape:",
    '{"summary": "2-4 sentences: what this file is for in the project and who uses it",',
    ' "changes": "2-5 sentences: what changed in this step, why it matters, and what a reviewer should keep in mind",',
    ' "comments": [{"block": "B1", "line": 42, "text": "..."}]}',
    M.COMMENT_RULES,
    "Put identifiers in backticks.",
  }, "\n")
end

-- opts: { force = bool, prefetch = bool }
function M.ensure(ctx, opts)
  opts = opts or {}
  local f = ctx.file
  if f.binary or f.generated then return end
  local key = M.key(ctx)
  if M.status[key] == "pending" then return end
  if not opts.force and M.get(ctx) then return end
  if not opts.force and not opts.manual and not config.options.ai.comment_on_open then return end
  M.status[key] = "pending"
  require("reviewer.core").changed()
  if not opts.prefetch then ui.notify("Claude is commenting " .. f.path .. "…") end
  claude.run(prompt(ctx), { json = true, tools = config.options.claude.explain_tools, cwd = ctx.dir, use = "comments" }, function(err, res)
    if err or type(res) ~= "table" or type(res.comments) ~= "table" then
      M.status[key] = "error: " .. (err or "unexpected reply")
      if not opts.prefetch then ui.notify("comments for " .. f.path .. " failed: " .. (err or "unexpected reply"), vim.log.levels.WARN) end
    else
      M.store(ctx, res)
      M.status[key] = nil
      if not opts.prefetch then ui.notify("comments ready for " .. f.path) end
      if config.options.ai.prefetch_next and not opts.force and not opts.prefetch then M.prefetch_after(ctx) end
    end
    require("reviewer.core").changed()
  end)
end

-- Comment the next unread file in the background.
function M.prefetch_after(ctx)
  local core = require("reviewer.core")
  local files = core.ordered(ctx.step, { hide_generated = true })
  local seen = false
  for _, f in ipairs(files) do
    if seen and not core.is_read(f.path, ctx.step) and not f.binary then
      local nctx = core.make_ctx(ctx.step, f)
      if nctx and not M.get(nctx) then M.ensure(nctx, { prefetch = true }) end
      return
    end
    if f.path == ctx.file.path then seen = true end
  end
end

return M
