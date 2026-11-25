-- Session state shared by every module: the active project and step,
-- the files of each step, and which buffer shows which reviewed file.
local config = require("stackreview.config")
local state = require("stackreview.state")
local git = require("stackreview.git")
local ui = require("stackreview.ui")

local M = {
  project = nil, -- active project table
  step = nil, -- active step table
  buffers = {}, -- bufnr -> ctx { project, step, file, path, hunks, dir }
  listeners = {}, -- callbacks run after any change worth redrawing
}

function M.on_change(fn) M.listeners[#M.listeners + 1] = fn end
function M.changed() for _, fn in ipairs(M.listeners) do pcall(fn) end end

local function project_for_cwd()
  local cwd = vim.fs.normalize(vim.uv.cwd() or "")
  for _, name in ipairs(config.project_names()) do
    local p = config.project(name)
    if cwd:sub(1, #p.root) == p.root or cwd:sub(1, #p.worktrees) == p.worktrees then return p end
  end
end

function M.activate(name)
  local p = name and config.project(name) or project_for_cwd() or config.project(config.project_names()[1] or "")
  if not p then
    ui.notify("no project configured. Add one in setup({ projects = { ... } }).", vim.log.levels.ERROR)
    return nil
  end
  M.project = p
  local st = state.get(p)
  local sid = tonumber(st.ui.step or "1") or 1
  M.step = p.steps[sid] or p.steps[1]
  return p
end

function M.set_step(id)
  if not M.project then return end
  local s = M.project.steps[tonumber(id) or 0]
  if not s then return ui.notify("no step " .. tostring(id), vim.log.levels.WARN) end
  M.step = s
  state.get(M.project).ui.step = s.id
  state.save(M.project)
  M.changed()
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

-- Files of the step in panel order, honouring the filters.
function M.ordered(step, opts)
  step = step or M.step
  opts = opts or {}
  local files = {}
  for _, f in ipairs(M.files(step)) do
    if not (opts.hide_generated and f.generated) then files[#files + 1] = f end
  end
  if (opts.order or config.options.order) == "reading" then
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
  local diff = require("stackreview.diff")
  local dir, err = git.step_dir(M.project, step, true)
  if not dir then
    ui.notify(err or ("no folder for step " .. step.id), vim.log.levels.WARN)
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

-- Which step folder and file a path belongs to (for buffers opened any way).
function M.locate(abs)
  if not M.project then return nil end
  abs = vim.fs.normalize(abs)
  for _, step in ipairs(M.project.steps) do
    local dir = git.step_dir(M.project, step, false)
    if dir and abs:sub(1, #dir + 1) == dir .. "/" then
      local rel = abs:sub(#dir + 2)
      local f = git.find_file(M.project, step, rel)
      if f then return step, f, dir end
    end
  end
end

return M
