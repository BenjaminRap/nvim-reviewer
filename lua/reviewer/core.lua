-- Session state shared by every module: the repository and the review (two
-- branches) being looked at, and which buffer shows which reviewed file.
-- A review is called a "step" in the code: { id, label, base_branch, branch, base_ref, head_ref }.
local config = require("reviewer.config")
local state = require("reviewer.state")
local git = require("reviewer.git")
local ui = require("reviewer.ui")

local M = {
  project = nil, -- the repository's settings (config.repo)
  step = nil, -- the current review
  buffers = {}, -- bufnr -> ctx { project, step, file, path, hunks, dir }
  listeners = {}, -- callbacks run after any change worth redrawing
}

function M.on_change(fn) M.listeners[#M.listeners + 1] = fn end
function M.changed() for _, fn in ipairs(M.listeners) do pcall(fn) end end

-- Repository of the current directory.
function M.repo_here()
  local out = git.run({ "rev-parse", "--show-toplevel" }, vim.uv.cwd())
  if not out then return nil end
  local root = vim.trim(out)
  -- inside the hidden checkout, use the repository it belongs to
  local common = git.run({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, root)
  if common then
    common = vim.fs.normalize(vim.trim(common))
    if vim.fs.basename(common) == ".git" then root = vim.fs.dirname(common) end
  end
  return config.repo(root)
end

-- `name` as given: <remote>/<name> when that ref exists, else the name itself.
function M.resolve(repo, name)
  if not name or name == "" then return nil end
  if name:sub(1, #repo.remote + 1) == repo.remote .. "/" and git.rev(repo, name) then return name end
  local remote = repo.remote .. "/" .. name
  if git.rev(repo, remote) then return remote end
  if git.rev(repo, name) then return name end
  return nil
end

-- Review object from a pair of names ("main", "feature") or an id ("main..feature").
function M.review(repo, base, head)
  if head == nil and base and base:find("%.%.") then base, head = base:match("^(.-)%.%.(.*)$") end
  local base_ref, head_ref = M.resolve(repo, base), M.resolve(repo, head)
  if not base_ref then return nil, "unknown branch '" .. tostring(base) .. "' (run :ReviewFetch?)" end
  if not head_ref then return nil, "unknown branch '" .. tostring(head) .. "' (run :ReviewFetch?)" end
  local id = base .. ".." .. head
  return { id = id, label = base .. " → " .. head, base_branch = base, branch = head, base_ref = base_ref, head_ref = head_ref }
end

-- Start (or switch to) a review in the repository of the current directory.
function M.start(base, head)
  local repo = M.repo_here()
  if not repo then
    ui.notify("not inside a git repository", vim.log.levels.ERROR)
    return nil
  end
  local review, err = M.review(repo, base, head)
  if not review then
    ui.notify(err, vim.log.levels.ERROR)
    return nil
  end
  local switching = M.step and M.step.id ~= review.id
  M.project, M.step = repo, review
  if switching then
    M.forget_buffers()
    require("reviewer.browser").wipe()
  end
  local st = state.get(repo)
  st.ui.last = { base = review.base_branch, head = review.branch }
  st.reviews = st.reviews or {}
  st.reviews[review.id] = { base = review.base_branch, head = review.branch, at = state.now() }
  state.save(repo)
  return review
end

-- Drop the overlays of the previous review; reload files of the hidden checkout,
-- which is about to move to another commit.
function M.forget_buffers()
  local render = require("reviewer.render")
  for buf in pairs(M.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, render.ns, 0, -1)
      pcall(function() vim.bo[buf].modifiable = true ; vim.bo[buf].readonly = false end)
    end
  end
  M.buffers, M.current = {}, nil
end

-- Quiz file of a review id ("main..feature" -> quiz-main..feature.json).
function M.quiz_file(id)
  return M.project.quiz_dir .. "/quiz-" .. id:gsub("[^%w%-_.]", "_") .. ".json"
end

-- The last review of this repository, if any.
function M.last(repo)
  local l = state.get(repo).ui.last
  if l and l.base and l.head then return l.base, l.head end
end

function M.files(step)
  return git.changed_files(M.project, step or M.step)
end

-- Reading-order group of a path for this project.
function M.group_of(file)
  if file.generated then return { label = "Generated files", order = 99 } end
  for _, g in ipairs(M.project.groups) do
    for _, pat in ipairs(g.patterns) do
      if file.path:find(pat) then return g end
    end
  end
  return { label = "Other", order = 98 }
end

-- Files of the review in display order, honouring the filters.
function M.ordered(step, opts)
  step = step or M.step
  opts = opts or {}
  local files = {}
  for _, f in ipairs(M.files(step)) do
    if not (opts.hide_generated and f.generated) then files[#files + 1] = f end
  end
  if (opts.order or "reading") == "reading" then
    table.sort(files, function(a, b)
      local ga, gb = M.group_of(a), M.group_of(b)
      if ga.order ~= gb.order then return ga.order < gb.order end
      return a.path < b.path
    end)
  else
    table.sort(files, function(a, b) return a.path < b.path end)
  end
  return files
end

function M.is_read(path, step) return state.is_read(M.project, (step or M.step).id, path) end

function M.reviewable(step)
  local n, read = 0, 0
  for _, f in ipairs(M.files(step)) do
    if not f.generated then
      n = n + 1
      if M.is_read(f.path, step) then read = read + 1 end
    end
  end
  return read, n
end

-- Everything needed to show and comment one file of a step.
function M.make_ctx(step, f)
  local diff = require("reviewer.diff")
  local dir, err = git.step_dir(M.project, step, true)
  if not dir then
    ui.notify(err or "no checkout for this review", vim.log.levels.WARN)
    return nil
  end
  local text = git.diff(M.project, step, f)
  local ctx = { project = M.project, step = step, file = f, dir = dir, hunks = diff.parse(text), hash = vim.fn.sha256(text) }
  if f.status == "D" then
    ctx.deleted = true
    ctx.lines = {}
  else
    local fh = io.open(dir .. "/" .. f.path, "r")
    local content = fh and fh:read("*a") or ""
    if fh then fh:close() end
    ctx.lines = vim.split(content, "\n", { plain = true })
    if ctx.lines[#ctx.lines] == "" then ctx.lines[#ctx.lines] = nil end
  end
  return ctx
end

-- The reviewed file a path belongs to, if any (for buffers opened any way).
function M.locate(abs)
  if not M.project or not M.step then return nil end
  abs = vim.fs.normalize(abs)
  local dir = git.step_dir(M.project, M.step, false)
  if dir and abs:sub(1, #dir + 1) == dir .. "/" then
    local f = git.find_file(M.project, M.step, abs:sub(#dir + 2))
    if f then return M.step, f, dir end
  end
end

return M
