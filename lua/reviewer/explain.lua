-- Claude's comments on a file: a summary, what changed, and a comment per change block.
-- Written once per file and saved. Each comment keeps a fingerprint of its
-- block, so when the diff changes (a rebase, a new commit) the comments of
-- unchanged blocks are kept and only new or changed blocks go to Claude.
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

-- Fingerprint of a change block: its removed and added lines (not its place).
function M.block_hash(h)
  return vim.fn.sha256(table.concat(h.removed, "\n") .. "\0" .. table.concat(h.added, "\n"))
end

-- The block "B3" (Claude sometimes writes "b3", "B 3" or "3").
local function block_id(b)
  b = tostring(b or ""):upper():gsub("%s", "")
  return b:match("^%d+$") and ("B" .. b) or b
end
M.block_id = block_id

-- After the diff of a file changed: the comments of blocks whose content did
-- not change, moved to where those blocks are now, and the blocks that still
-- need comments. nil when there is nothing to reuse (no saved comments, the
-- same diff, comments saved before blocks had fingerprints, a deleted file).
function M.reusable(ctx)
  local e = state.explain(ctx.project).files[M.key(ctx)]
  if not e or e.hash == ctx.hash or type(e.blocks) ~= "table" or ctx.deleted then return nil end
  local known, by = {}, {}
  for _, b in ipairs(e.blocks) do known[b] = true end
  for _, c in ipairs(e.comments or {}) do
    if c.bh then by[c.bh] = by[c.bh] or {}; table.insert(by[c.bh], c) end
  end
  local kept, todo = {}, {}
  for _, h in ipairs(ctx.hunks) do
    local bh = M.block_hash(h)
    if known[bh] then
      for _, c in ipairs(by[bh] or {}) do
        kept[#kept + 1] = { block = h.id, line = c.off and (h.new_start + c.off) or nil, text = c.text, bh = bh, off = c.off }
      end
    else
      todo[#todo + 1] = h.id
    end
  end
  return { entry = e, kept = kept, todo = todo }
end

-- Comments saved before blocks had fingerprints: add them (same diff, so the blocks are known).
local function add_fingerprints(ctx, e)
  local by_id = {}
  for _, h in ipairs(ctx.hunks or {}) do by_id[h.id] = h end
  e.blocks = {}
  for _, h in ipairs(ctx.hunks or {}) do e.blocks[#e.blocks + 1] = M.block_hash(h) end
  for _, c in ipairs(e.comments or {}) do
    local h = by_id[block_id(c.block)]
    if h then
      c.bh = M.block_hash(h)
      if c.line and c.line >= h.new_start and c.line < h.new_start + math.max(h.new_count, 1) then c.off = c.line - h.new_start end
    end
  end
  state.save(ctx.project, "explain")
end

-- Blocks of at least `claude.gap_lines` added lines that have no comment
-- (neither on the block nor on one of its lines). Checked in code after each
-- reply; Claude is then asked about these blocks only.
function M.gaps(ctx)
  local e = state.explain(ctx.project).files[M.key(ctx)]
  local min = config.options.claude.gap_lines or 5
  if not e or e.hash ~= ctx.hash or ctx.deleted or not ctx.hunks or min <= 0 then return {} end
  local covered = {}
  for _, h in ipairs(ctx.hunks) do
    for _, c in ipairs(e.comments or {}) do
      local l = tonumber(c.line)
      if block_id(c.block) == h.id or (l and l >= h.new_start and l < h.new_start + h.new_count) then covered[h.id] = true end
    end
  end
  local out = {}
  for _, h in ipairs(ctx.hunks) do
    if h.new_count >= min and not covered[h.id] then out[#out + 1] = h.id end
  end
  return out
end

-- What to send for a second round on the gaps: every saved comment is kept.
function M.gap_reuse(ctx)
  local e = state.explain(ctx.project).files[M.key(ctx)]
  local gaps = M.gaps(ctx)
  if not e or #gaps == 0 then return nil end
  return { entry = e, kept = vim.deepcopy(e.comments or {}), todo = gaps, gaps = true }
end

function M.get(ctx)
  local key = M.key(ctx)
  local e = state.explain(ctx.project).files[key]
  if e and e.hash == ctx.hash then
    if type(e.blocks) ~= "table" and not ctx.deleted and ctx.hunks then add_fingerprints(ctx, e) end
    return e
  end
  -- every block unchanged (lines moved, or the diff around them changed): no Claude call
  local r = e and M.reusable(ctx)
  if r and #r.todo == 0 then
    M.store(ctx, { summary = e.summary, changes = e.changes, comments = {} }, r)
    return state.explain(ctx.project).files[key]
  end
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
-- links_for: { [path] = true }, the files whose cross-file facts (found by
-- the overview) are added, so the call does not search for them again.
function M.step_context(project, step, max_roles, links_for)
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
    if links_for and o.files then
      local facts = {}
      for _, fr in ipairs(o.files) do
        if links_for[fr.path] and fr.links and #fr.links > 0 then
          facts[#facts + 1] = "- " .. fr.path .. ":"
          for _, l in ipairs(fr.links) do facts[#facts + 1] = "  - " .. l end
        end
      end
      if #facts > 0 then
        lines[#lines + 1] = "Cross-file facts already checked while writing the overview (use them instead of searching again):"
        vim.list_extend(lines, facts)
      end
    end
  end
  return table.concat(lines, "\n")
end

-- Characters of a deleted file sent to Claude: enough to say what it did.
M.DELETED_CHARS = 4000

-- Header + listing for one file (also used for batches). A deleted file is
-- not commented block by block: only its start is sent, for a short summary.
function M.file_section(ctx)
  local f = ctx.file
  local commits = {}
  for _, c in ipairs(git.commits(ctx.project, ctx.step, f.path)) do commits[#commits + 1] = c.subject end
  local body
  if ctx.deleted then
    local old = {}
    for _, h in ipairs(ctx.hunks) do vim.list_extend(old, h.removed) end
    body = table.concat(old, "\n")
    if #body > M.DELETED_CHARS then body = body:sub(1, M.DELETED_CHARS) .. "\n…(rest of the deleted file left out)" end
    body = "This file is DELETED: give only \"summary\" (what it did) and \"changes\" (why it is gone and what replaces it, if the code shows it), with an empty \"comments\" list. Its old content starts with:\n" .. body
  else
    body = diff.listing(ctx.lines, ctx.hunks, 150000)
    if ctx.reuse and ctx.reuse.gaps then
      body = ("Blocks %s have no comment yet: write comments for these blocks only (the other blocks already have theirs). \"summary\" and \"changes\" may be left empty.\n"):format(table.concat(ctx.reuse.todo, ", ")) .. body
    elseif ctx.reuse and #ctx.reuse.todo < #ctx.hunks then
      body = ("Only blocks %s are new or changed since this file was last commented: write comments for these blocks only (the other blocks keep their comments), and write \"summary\" and \"changes\" again for the whole file.\n"):format(table.concat(ctx.reuse.todo, ", ")) .. body
    end
  end
  return table.concat({
    ("=== FILE %s (%s%s, +%d −%d)"):format(f.path, STATUS[f.status] or f.status, f.old and (" from " .. f.old) or "", f.add, f.del),
    "Commits touching it: " .. table.concat(commits, " | "):sub(1, 1000),
    body,
  }, "\n")
end

M.LISTING_HELP = "Each file is shown whole. Each line shows its new line number, then \"+\" for an added line, \"-\" for a removed line (with its old number), or a space for an unchanged line. Every run of changed lines is a block, introduced by \"### B<n>\"."

M.COMMENT_RULES = table.concat({
  "Rules for comments:",
  "- Comment every block that is not trivial; group tiny related blocks (imports, renames) into one comment on the first of them.",
  "- For a large block (more than about 25 lines, for example a new file), add one comment at the start of each logical section (function, component, route handler, type, test case), with \"line\" set to that section's first new line number. Otherwise \"line\" may be omitted.",
  "- Each comment: 1-4 sentences in plain English saying what the code does, how, and why; point out anything worth double-checking (edge cases, security, error handling). When it helps, say which other file uses this code or is used by it (path:line).",
  "- Use the overview and the cross-file facts above first. Open or search other files only when what you need is not there; do not check again what they already say.",
  "- Only state what the code shows. Never invent behaviour. At most 45 comments per file.",
  "- A deleted file gets no comments, only its summary and changes.",
}, "\n")

-- Save Claude's reply for one file. reuse (from M.reusable): the comments
-- kept from before are added, and Claude's comments are kept only on the
-- blocks it was asked about.
function M.store(ctx, res, reuse)
  local by_id = {}
  for _, h in ipairs(ctx.hunks or {}) do by_id[h.id] = h end
  local asked
  if reuse then
    asked = {}
    for _, id in ipairs(reuse.todo) do asked[id] = true end
  end
  local comments = {}
  for _, c in ipairs(type(res.comments) == "table" and res.comments or {}) do
    if type(c) == "table" and c.text and c.text ~= "" then
      local id = block_id(c.block)
      local h, line = by_id[id], tonumber(c.line)
      if not asked or asked[id] then
        local off = (h and line and line >= h.new_start and line < h.new_start + math.max(h.new_count, 1)) and (line - h.new_start) or nil
        comments[#comments + 1] = { block = id, line = line, text = tostring(c.text), bh = h and M.block_hash(h) or nil, off = off }
      end
    end
  end
  if reuse then vim.list_extend(comments, reuse.kept) end
  local blocks = {}
  for _, h in ipairs(ctx.hunks or {}) do blocks[#blocks + 1] = M.block_hash(h) end
  -- a second round on the gaps may leave the summary and changes out
  local old = reuse and reuse.entry or {}
  local function text(v, keep) v = v and tostring(v) or ""; return v ~= "" and v or (keep or "") end
  state.explain(ctx.project).files[M.key(ctx)] = {
    hash = ctx.hash, step = ctx.step.id, path = ctx.file.path,
    summary = text(res.summary, old.summary), changes = text(res.changes, old.changes),
    comments = comments, blocks = blocks, at = state.now(),
  }
  state.save(ctx.project, "explain")
end

local function prompt(ctx)
  return table.concat({
    "You explain code changes to a developer who is reviewing their team's code and wants to understand it deeply.",
    "",
    M.step_context(ctx.project, ctx.step, 80, { [ctx.file.path] = true }),
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
  if not opts.gaps then ctx.reuse = not opts.force and M.reusable(ctx) or nil end
  require("reviewer.core").changed()
  if not opts.prefetch then ui.notify("Claude is commenting " .. f.path .. "…") end
  claude.run(prompt(ctx), { json = true, tools = config.options.claude.explain_tools, cwd = ctx.dir, use = "comments" }, function(err, res)
    if err or type(res) ~= "table" or type(res.comments) ~= "table" then
      M.status[key] = "error: " .. (err or "unexpected reply")
      if not opts.prefetch then ui.notify("comments for " .. f.path .. " failed: " .. (err or "unexpected reply"), vim.log.levels.WARN) end
    else
      M.store(ctx, res, ctx.reuse)
      M.status[key] = nil
      if not opts.gaps then
        local g = M.gap_reuse(ctx)
        if g then
          ctx.reuse = g
          return M.ensure(ctx, vim.tbl_extend("force", opts, { force = true, gaps = true, manual = true }))
        end
      end
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
