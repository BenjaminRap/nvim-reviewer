-- Git access: changed files per step, diffs, commits and one folder per step.
-- Only reads remote-tracking refs; never pulls, merges or pushes.
local M = {}

local cache = {}

function M.run(args, cwd)
  local cmd = vim.list_extend({ "git" }, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then return nil, (res.stderr or ""):gsub("%s+$", "") end
  return res.stdout
end

function M.rev(project, ref, cwd)
  local out = M.run({ "rev-parse", "--verify", "-q", ref .. "^{commit}" }, cwd or project.root)
  return out and vim.trim(out) or nil
end

function M.clear_cache() cache = {} end

local function is_generated(project, path)
  for _, pat in ipairs(project.generated) do
    if path:find(pat) then return true end
  end
  return false
end

-- Files changed between a step's base and head:
-- { path, old, status, add, del, binary, generated }
function M.changed_files(project, step)
  local key = project.name .. ":files:" .. step.id
  if cache[key] then return cache[key] end
  local ns, err = M.run({ "diff", "-M", "--numstat", step.base_ref, step.head_ref }, project.root)
  if not ns then
    vim.notify("reviewer: git diff failed for step " .. step.id .. ": " .. err, vim.log.levels.ERROR)
    return {}
  end
  local st = M.run({ "diff", "-M", "--name-status", step.base_ref, step.head_ref }, project.root) or ""
  local nlines, slines = vim.split(ns, "\n", { trimempty = true }), vim.split(st, "\n", { trimempty = true })
  local files = {}
  for i, n in ipairs(nlines) do
    local a, d = n:match("^(%S+)\t(%S+)\t")
    local parts = vim.split(slines[i] or "", "\t")
    local status = (parts[1] or "M"):sub(1, 1)
    local path = parts[#parts]
    local f = {
      path = path,
      old = status == "R" and parts[2] or nil,
      status = status,
      binary = a == "-",
      add = tonumber(a) or 0,
      del = tonumber(d) or 0,
    }
    f.generated = is_generated(project, path)
    files[#files + 1] = f
  end
  cache[key] = files
  return files
end

function M.find_file(project, step, path)
  for _, f in ipairs(M.changed_files(project, step)) do
    if f.path == path then return f end
  end
end

-- Unified diff with no context lines for one file of a step.
function M.diff(project, step, f)
  local key = project.name .. ":diff:" .. step.id .. ":" .. f.path
  if cache[key] then return cache[key] end
  local paths = f.old and { f.old, f.path } or { f.path }
  local out = M.run(vim.list_extend({ "diff", "-M", "-U0", "--no-color", step.base_ref, step.head_ref, "--" }, paths), project.root) or ""
  cache[key] = out
  return out
end

function M.show(project, ref, path)
  return M.run({ "show", ref .. ":" .. path }, project.root)
end

-- Commits of a step, optionally only those touching a path: { hash, subject, author, date }
function M.commits(project, step, path)
  local key = project.name .. ":log:" .. step.id .. ":" .. (path or "")
  if cache[key] then return cache[key] end
  local args = { "log", "--format=%h%x1f%s%x1f%an%x1f%ad", "--date=short", step.base_ref .. ".." .. step.head_ref }
  if path then vim.list_extend(args, { "--", path }) end
  local out = M.run(args, project.root) or ""
  local list = {}
  for _, l in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local h, s, a, d = l:match("^(.-)\31(.-)\31(.-)\31(.*)$")
    if h then list[#list + 1] = { hash = h, subject = s, author = a, date = d } end
  end
  cache[key] = list
  return list
end

-- Folder holding the files of the review as they are at its head branch.
-- Your own checkout is used when it already sits on that commit; otherwise one
-- hidden checkout per repository (config `worktree_dir`) is created or moved there.
function M.step_dir(project, step, create)
  if step._dir then return step._dir end
  local dir, err = M._step_dir(project, step, create)
  step._dir = dir
  return dir, err
end

function M._step_dir(project, step, create)
  local head = M.rev(project, step.head_ref)
  if not head then return nil, "unknown ref " .. step.head_ref .. " (run :Review fetch?)" end
  if M.rev(project, "HEAD") == head then return project.root end
  local dir = project.worktree
  if vim.uv.fs_stat(dir) then
    if M.rev(project, "HEAD", dir) == head then return dir end
    if not create then return nil end
    local dirty = M.run({ "status", "--porcelain" }, dir)
    if dirty and dirty ~= "" then
      return nil, "the hidden checkout " .. dir .. " has local changes; commit or discard them there, or delete it with :Review clean"
    end
    local _, err = M.run({ "checkout", "--quiet", "--detach", step.head_ref }, dir)
    if err then return nil, "could not move the hidden checkout: " .. err end
    return dir
  end
  if not create then return nil end
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  M.run({ "worktree", "prune" }, project.root)
  local _, err = M.run({ "worktree", "add", "--detach", dir, step.head_ref }, project.root)
  if err then return nil, "git worktree add failed: " .. err end
  return dir
end

-- Remove the hidden checkout of a repository.
function M.remove_worktree(project)
  if not vim.uv.fs_stat(project.worktree) then return true end
  local _, err = M.run({ "worktree", "remove", "--force", project.worktree }, project.root)
  if err then return nil, err end
  M.run({ "worktree", "prune" }, project.root)
  return true
end

function M.fetch(project)
  return M.run({ "fetch", "--prune", project.remote }, project.root)
end

return M
