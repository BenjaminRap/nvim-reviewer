-- Options, project definitions and the review steps derived from them.
local M = {}

M.defaults = {
  -- name -> project definition (see README)
  projects = {},
  claude = {
    cmd = "claude",
    -- Model per use: an alias ("opus", "sonnet", "haiku") or a full model name.
    -- false or nil uses `model` below, then your Claude Code default.
    models = {
      overview = "opus", -- one call per step; its summary is the context for everything else
      comments = "sonnet", -- most of the calls (every file), so the cheaper model
      quiz = "opus", -- one call per step; accuracy matters most
      final = "opus", -- the final quiz on the whole stack
      ask = "opus", -- your questions and quiz hints
      grade = "sonnet", -- open answers, checked against a reference answer
    },
    model = nil, -- used for any use without its own model; nil = Claude Code's default
    fallback_model = "sonnet", -- used if the chosen model is busy or not available on your plan
    -- tools Claude may use; "" means none. Asking runs in the step's folder,
    -- so read-only tools let Claude open any file of the repo at that step.
    explain_tools = "Read,Grep,Glob",
    ask_tools = "Read,Grep,Glob",
    grade_tools = "",
    prepare_tools = "Read,Grep,Glob",
    batch_chars = 60000, -- size of one batch of files sent together when preparing a step
    batch_files = 6,
    extra_args = {},
    timeout_ms = 10 * 60 * 1000,
    max_parallel = 2,
  },
  -- When Claude runs. Everything else is on demand (panel actions, keys, commands).
  ai = {
    -- On :Review: "ask" (offer to prepare the current step), "step" (prepare it
    -- without asking), "all" (prepare every step and the final quiz), "never".
    on_start = "ask",
    comment_on_open = false, -- comment a file automatically the first time it is opened
    prefetch_next = false, -- then also comment the next unread file in the background
    offer_missing_quiz = true, -- offer to write a quiz when you open one that does not exist
    grade_open_answers = true, -- Claude grades open answers; false = you grade yourself
  },
  show_comments = true,
  hide_generated = true,
  order = "reading", -- "reading" (groups) or "tree" (folders)
  panel = { width = 48 },
  comment_width = 100,
  keymaps = {
    next_change = "]c",
    prev_change = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_read = "<leader>rr",
    read_next = "<leader>rn",
    note = "<leader>rN",
    ask = "<leader>ra",
    explain = "<leader>re",
    panel = "<leader>rp",
  },
  -- Reading order: the first group whose pattern matches a path wins.
  -- Patterns are Lua patterns. `order` sets the display order.
  groups = {
    { label = "Tests", order = 90, patterns = { "/tests?/", "^tests?/", "%.test%.", "%.spec%." } },
    { label = "Database schema & migrations", order = 10, patterns = { "^prisma/", "migrations?/", "%.sql$" } },
    { label = "Shared code", order = 20, patterns = { "shared/" } },
    { label = "Backend", order = 40, patterns = { "backend/", "server/" } },
    { label = "Frontend", order = 60, patterns = { "frontend/", "client/" } },
    { label = "Config, docs, other", order = 95, patterns = { "" } },
  },
  -- Files hidden by default (lockfiles, generated code). Lua patterns.
  generated = { "package%-lock%.json$", "yarn%.lock$", "pnpm%-lock%.yaml$" },
}

M.options = vim.deepcopy(M.defaults)

local function expand(p) return p and vim.fs.normalize(vim.fn.expand(p)) or nil end

local function normalize_project(name, p)
  assert(p.root, "stackreview: project '" .. name .. "' needs a root")
  assert(type(p.stack) == "table" and #p.stack > 0, "stackreview: project '" .. name .. "' needs a stack of branches")
  local proj = vim.tbl_extend("force", {
    remote = "origin",
    base = "main",
    labels = {},
  }, p)
  proj.name = name
  proj.root = expand(p.root)
  proj.worktrees = expand(p.worktrees) or (vim.fs.dirname(proj.root) .. "/" .. vim.fs.basename(proj.root) .. "-review")
  proj.data_dir = vim.fn.stdpath("data") .. "/stackreview/" .. name
  proj.quiz_dir = expand(p.quiz_dir) or (proj.data_dir .. "/quizzes")
  proj.groups = p.groups or M.options.groups
  proj.generated = vim.list_extend(vim.deepcopy(M.options.generated), p.generated or {})
  proj.steps = {}
  local prev = proj.base
  for i, branch in ipairs(proj.stack) do
    proj.steps[i] = {
      id = tostring(i),
      index = i,
      branch = branch,
      label = proj.labels[branch] or branch,
      base_branch = prev,
      base_ref = proj.remote .. "/" .. prev,
      head_ref = proj.remote .. "/" .. branch,
    }
    prev = branch
  end
  return proj
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- older option names
  if opts and opts.auto_explain ~= nil then M.options.ai.comment_on_open = opts.auto_explain end
  if opts and opts.prefetch_next ~= nil then M.options.ai.prefetch_next = opts.prefetch_next end
  -- `claude.model` alone means "this model for everything"
  if opts and opts.claude and opts.claude.model and not opts.claude.models then M.options.claude.models = {} end
  if opts and opts.groups then M.options.groups = opts.groups end
  local projects = {}
  for name, p in pairs(M.options.projects or {}) do projects[name] = normalize_project(name, p) end
  M.options.projects = projects
end

function M.project(name)
  return M.options.projects[name]
end

function M.project_names()
  local names = vim.tbl_keys(M.options.projects)
  table.sort(names)
  return names
end

return M
