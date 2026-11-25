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
  show_comments = true, -- Claude's comments above the code
  show_removed = true, -- removed lines shown in place, in red
  hide_generated = true,
  order = "reading", -- "reading" (groups) or "tree" (folders)
  comment_width = 100, -- maximum width of a comment box
  panel = {
    position = "left", -- "left" or "right"
    width = 48,
    icons = true, -- file icons from mini.icons or nvim-web-devicons, when installed
    show_actions = true, -- action lines at the top (prepare, overview, quizzes)
    show_file_summary = true, -- summary of the current file at the bottom
  },
  float = {
    border = "rounded",
    width = 0.8, -- floats (quiz, answers, progress): fraction of the editor, or columns if > 1
    height = 0.8,
    text_width = 96, -- wrap width of text in floats
  },
  symbols = {
    read = "x", unread = " ", partly_read = "-",
    fold_open = "▾", fold_closed = "▸",
    added = "+", removed = "-", -- signs in reviewed files
    removed_prefix = "- ", -- before each removed line shown in place
    comment = "✦", pending = "…",
    note = "●", question = "?", issue = "!", answer = "✦",
    action = "▶", stop = "■",
  },
  -- Every key can be a string, a list of strings, or false to disable it.
  keymaps = {
    -- in reviewed files (buffer-local)
    file = {
      next_change = "]c", prev_change = "[c",
      next_file = "]f", prev_file = "[f",
      toggle_read = "<leader>rr",
      read_next = "<leader>rn", -- mark read and open the next unread file
      note = "<leader>rN", -- normal or visual mode
      ask = "<leader>ra", -- normal or visual mode
      explain = "<leader>re", -- Claude's comments on the file
      about = "<leader>ri",
    },
    -- in the file panel. Defaults avoid keys that move the cursor or search,
    -- so j/k, w/b/e, f/t, n/N, gg/G, / and ? keep working.
    panel = {
      open = { "<CR>", "o" }, -- open a file, fold a group, run an action line
      fold = { "<Tab>", "za" },
      toggle_read = "x", -- file, group or folder
      read_next = "X",
      toggle_order = "s", -- reading order / folders
      toggle_generated = "i",
      toggle_hide_read = "r",
      pick_step = "p", next_step = "]s", prev_step = "[s",
      explain = "c", -- comment the file under the cursor
      explain_group = "C", -- comment every file of the group/folder under the cursor
      about = "a",
      prepare = "A", stop = "D",
      overview = "O",
      quiz = "Q", final_quiz = "gQ",
      progress = "P", notes = "gn",
      toggle_comments = "gc",
      close = "q", help = "g?",
    },
    quiz = {
      choices = "abcdef", -- one key per choice; "" to use only toggle_choice
      toggle_choice = "<Space>", -- toggle the choice under the cursor
      check = "<CR>", -- check the answer, or go to the next question once checked
      answer = "i", -- write an open answer
      dont_know = "d",
      next = "J", prev = "K",
      retry = "r",
      hint = "gh", explain = "x",
      overview = "o",
      refs = { "1", "2", "3", "4" }, -- open the code a question refers to
      self_correct = "+", self_partial = "~", self_wrong = "-",
      close = { "q", "<Esc>" },
    },
    progress = { open = "<CR>", retry_mistakes = "m", notes = "gn", asks = "A" },
    float = { close = { "q", "<Esc>" } },
    input = { submit = "<C-s>", submit_normal = "<CR>", cancel = { "q", "<Esc>" } },
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
  assert(p.root, "reviewer: project '" .. name .. "' needs a root")
  assert(type(p.stack) == "table" and #p.stack > 0, "reviewer: project '" .. name .. "' needs a stack of branches")
  local proj = vim.tbl_extend("force", {
    remote = "origin",
    base = "main",
    labels = {},
  }, p)
  proj.name = name
  proj.root = expand(p.root)
  proj.worktrees = expand(p.worktrees) or (vim.fs.dirname(proj.root) .. "/" .. vim.fs.basename(proj.root) .. "-review")
  proj.data_dir = vim.fn.stdpath("data") .. "/reviewer/" .. name
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
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists are replaced, not merged index by index.
  if opts.generated then M.options.generated = vim.deepcopy(opts.generated) end
  if opts.claude and opts.claude.extra_args then M.options.claude.extra_args = vim.deepcopy(opts.claude.extra_args) end
  local km = opts.keymaps or {}
  for section, keys in pairs(km) do
    if type(keys) == "table" and M.defaults.keymaps[section] then
      for name, lhs in pairs(keys) do M.options.keymaps[section][name] = lhs end
    end
  end
  -- older flat keymaps (keymaps.next_change, ...) belong to keymaps.file
  for name in pairs(M.defaults.keymaps.file) do
    if km[name] ~= nil then M.options.keymaps.file[name] = km[name] end
  end
  -- older option names
  if opts.auto_explain ~= nil then M.options.ai.comment_on_open = opts.auto_explain end
  if opts.prefetch_next ~= nil then M.options.ai.prefetch_next = opts.prefetch_next end
  -- `claude.model` alone means "this model for everything"
  if opts.claude and opts.claude.model and not opts.claude.models then M.options.claude.models = {} end
  if opts.groups then M.options.groups = opts.groups end
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
