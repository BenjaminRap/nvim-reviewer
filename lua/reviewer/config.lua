-- Options, project definitions and the review steps derived from them.
local M = {}

M.defaults = {
  -- Optional settings per repository, keyed by the repository's folder name
  -- (or give `root` to match a path). Nothing is needed to review a repo.
  repos = {},
  remote = "origin", -- branch names are read as <remote>/<name> when that exists
  base = "main", -- base branch when :Review gets only one branch
  -- One hidden checkout per repo, used when your own checkout is not on the head
  -- branch of the review. It is moved to the head of each new review.
  worktree_dir = vim.fn.stdpath("cache") .. "/reviewer",
  -- Dependencies of the hidden checkout, so the LSP finds the types of external
  -- packages (npm, pnpm or yarn, from the lockfile). Never in your own checkout.
  deps = {
    install = true, -- false: never install
    ignore_scripts = true, -- skip install scripts: no code of the reviewed branch runs
    cmd = nil, -- your own install command, e.g. { "npm", "ci" }
  },
  claude = {
    cmd = "claude",
    -- Model per use: an alias ("opus", "sonnet", "haiku") or a full model name.
    -- false or nil uses `model` below, then your Claude Code default.
    models = {
      overview = "opus", -- one call per review; its summary is the context for everything else
      comments = "sonnet", -- most of the calls (every file), so the cheaper model
      quiz = "opus", -- one call per review; accuracy matters most
      ask = "opus", -- your questions and quiz hints
      grade = "sonnet", -- open answers, checked against a reference answer
    },
    model = nil, -- used for any use without its own model; nil = Claude Code's default
    fallback_model = "sonnet", -- used if the chosen model is busy or not available on your plan
    -- tools Claude may use; "" means none. Claude runs in the checkout of the
    -- reviewed branch, so read-only tools let it open any file of the repo.
    explain_tools = "Read,Grep,Glob",
    ask_tools = "Read,Grep,Glob",
    grade_tools = "",
    prepare_tools = "Read,Grep,Glob",
    batch_chars = 120000, -- size of one batch of files sent together when preparing a review
    batch_files = 15, -- fewer, larger calls: each call pays Claude Code's own setup again
    usage_log = true, -- one line per call (tokens, turns, cost) in usage.jsonl of the repository's data folder
    extra_args = {},
    timeout_ms = 10 * 60 * 1000,
    max_parallel = 2,
  },
  -- When Claude runs. Everything else is on demand (browser keys, commands).
  ai = {
    -- When a review starts: "ask" (offer to prepare it), "step" (prepare it
    -- without asking), or "never".
    on_start = "ask",
    comment_on_open = false, -- comment a file automatically the first time it is opened
    prefetch_next = false, -- then also comment the next unread file in the background
    offer_missing_quiz = true, -- offer to write a quiz when you open one that does not exist
    grade_open_answers = true, -- Claude grades open answers; false = you grade yourself
  },
  show_comments = true, -- Claude's comments above the code
  comments = "inline", -- "inline" (boxes above the code) or "marker" (a ✦ in the sign column; keymaps.file.show_comment opens it)
  key_hints = true, -- a bar at the bottom listing the keys of the current review buffer (like lazygit)
  -- What the key bar shows, per buffer (file, browser, quiz), by keymap option
  -- name ("mark_read" is the browser's [x] + :w). hide: leave out keys you
  -- already know; show: add keys that are only in g? by default.
  -- Example: hide = { browser = { "open", "parent" } }
  key_bar = { hide = {}, show = {} },
  show_removed = true, -- removed lines shown in place, in red
  inline_changes = true, -- inside a changed line, the changed words are a little stronger (like GitHub)
  colors = "colorscheme", -- "colorscheme" (diff colours of your colorscheme), "github" (GitHub's colours) or "vivid" (green and red mixed into your background)
  layout = "inline", -- "inline" (changes drawn in the file) or "split" (before | after, Neovim's diff mode)
  -- Reviewed files cannot be changed: they may be in the hidden checkout (an edit
  -- there is on no branch) or in your own checkout (an edit changes your working
  -- copy). :Review edit unlocks one buffer.
  readonly = true,
  hide_generated = true,
  comment_width = 100, -- maximum width of a comment box
  browser = {
    view = "folders", -- first view: "folders" (one folder at a time, like oil) or "reading" (all files in reading order); then the last one used is kept
    icons = true, -- file icons from mini.icons or nvim-web-devicons, when installed
    show_unchanged = false, -- also list files the review does not change, dimmed
  },
  float = {
    border = "rounded",
    width = 0.8, -- floats (quiz, answers, progress): fraction of the editor, or columns if > 1
    height = 0.8,
    text_width = 96, -- wrap width of text in floats
  },
  symbols = {
    read = "x", unread = " ", partly_read = "-", -- browser checkboxes
    added = "+", removed = "-", -- signs in reviewed files
    removed_prefix = "- ", -- before each removed line shown in place
    comment = "✦", pending = "…",
    note = "✎", -- your notes
    next = "→", -- the next file to read (browser) and the reading path line (files)
  },
  -- Every key can be a string, a list of strings, or false to disable it.
  keymaps = {
    -- in reviewed files (buffer-local)
    file = {
      -- arrows first (shown in the key bar); the bracket keys work too
      next_change = { "<Down>", "]c" }, prev_change = { "<Up>", "[c" },
      next_file = { "<Right>", "]f" }, prev_file = { "<Left>", "[f" },
      toggle_read = "<leader>rr",
      read_next = "<leader>rn", -- mark read and open the next unread file
      ask = "<leader>ra", -- normal or visual mode
      explain = "<leader>re", -- Claude's comments on the file
      about = "<leader>ri",
      browse = "-", -- open the review browser on the file's folder (like oil's "-")
      toggle_split = "<leader>rs", -- inline changes / side by side
      comments_style = "<leader>rc", -- Claude's comments as boxes or as markers
      show_comment = "<leader>rh", -- Claude's comment of the code under the cursor; again: go into it
      note = "<leader>rm", -- your note on this line (visual: on the lines); on a note: edit it, empty deletes it
      help = "g?", -- every key, in a float
    },
    -- in the review browser. Its text is editable (read marks), so defaults
    -- leave every editing and moving key alone and use oil-like keys and g-keys.
    browser = {
      open = "<CR>", open_vsplit = "<C-s>", open_split = "<C-h>", open_tab = "<C-t>",
      preview = "<C-p>", parent = "-", root = "_", refresh = "<C-l>",
      toggle_view = "gs", -- folders / all files in reading order
      toggle_unchanged = "g.", toggle_generated = "gG",
      explain = "gC", -- Claude's comments on the file under the cursor
      explain_folder = "gF", -- comment every file of the folder under the cursor
      about = "gK",
      prepare = "gA", stop = "gS", overview = "gO", quiz = "gQ",
      progress = "gL", new_review = "gB",
      close = "<C-c>", -- back to the file shown before the browser (like oil's close)
      notes = "gN", -- every note of the review, in the quickfix list
      help = "g?",
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
    progress = { open = "<CR>", retry_mistakes = "m", asks = "A" },
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

local function expand_root(p) return p and vim.fs.normalize(vim.fn.expand(p)) or nil end

-- Settings of the repository at `root`, defaults filled in.
function M.repo(root)
  root = vim.fs.normalize(root)
  local name, user = vim.fs.basename(root), {}
  for key, r in pairs(M.options.repos or {}) do
    if (r.root and expand_root(r.root) == root) or (not r.root and key == vim.fs.basename(root)) then
      name, user = key, r
      break
    end
  end
  local repo = {
    name = name,
    root = root,
    remote = user.remote or M.options.remote,
    base = user.base or M.options.base,
    groups = user.groups or M.options.groups,
    generated = vim.list_extend(vim.deepcopy(M.options.generated), user.generated or {}),
    data_dir = vim.fn.stdpath("data") .. "/reviewer/" .. name,
    worktree = expand_root(user.worktree) or (M.options.worktree_dir .. "/" .. name),
  }
  repo.quiz_dir = expand_root(user.quiz_dir) or (repo.data_dir .. "/quizzes")
  return repo
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
  -- older name of `repos`
  if opts.projects then M.options.repos = vim.tbl_extend("force", opts.projects, opts.repos or {}) end
  M.options.worktree_dir = vim.fs.normalize(vim.fn.expand(M.options.worktree_dir))
  if M.options.ai.on_start == "all" then M.options.ai.on_start = "step" end
  -- older name of "marker" (the comment no longer opens on its own)
  if M.options.comments == "hover" then M.options.comments = "marker" end
end

return M
