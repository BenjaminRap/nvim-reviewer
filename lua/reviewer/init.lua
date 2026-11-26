-- nvim-reviewer: review a stack of branches step by step, file by file,
-- with Claude's comments, quizzes and saved progress.
local config = require("reviewer.config")

local M = {}

local did_setup = false

function M.setup(opts)
  config.setup(opts)
  require("reviewer.render").setup_highlights()
  if did_setup then return end
  did_setup = true
  local group = vim.api.nvim_create_augroup("reviewer", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() require("reviewer.render").setup_highlights() end })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      local core = require("reviewer.core")
      if not core.project then return end
      local review = require("reviewer.review")
      local win = vim.api.nvim_get_current_win()
      -- the main window shows files, not the browser or the "before" side of a split
      if vim.api.nvim_win_get_config(win).relative == "" and not vim.api.nvim_buf_get_name(ev.buf):match("^reviewer://") then review.last_win = win end
      require("reviewer.split").check(win, ev.buf)
      review.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(ev) require("reviewer.core").buffers[ev.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function() if require("reviewer.core").project then require("reviewer.render").draw_all() end end })
  require("reviewer.keybar").setup(group)
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() require("reviewer.state").flush_all() end })
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

-- Open the current review: its checkout, the browser, the overlays.
local function open_review()
  local core, git, ui = require("reviewer.core"), require("reviewer.git"), require("reviewer.ui")
  git.clear_cache()
  require("reviewer.quiz").reload()
  local dir, err = git.step_dir(core.project, core.step, true)
  if not dir then ui.notify(err or "no checkout for this review", vim.log.levels.ERROR) end
  if dir then require("reviewer.deps").ensure(core.project, dir) end
  -- files of the hidden checkout may now show another commit: reload them
  local wt = core.project.worktree
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name:sub(1, #wt + 1) == wt .. "/" and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent! edit!") end)
    end
  end
  require("reviewer.browser").open({ dir = "" })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then require("reviewer.review").attach(buf) end
  end
  require("reviewer.core").changed()
  if not require("reviewer.core").step.parent then
    vim.schedule(function() require("reviewer.prepare").offer_on_start() end)
  end
end

-- Start a review from two branch names, or from an id "base..head".
-- opts: { label, parent } for the review of one commit of a branch.
function M.start_review(base, head, opts)
  ensure_setup()
  if not require("reviewer.core").start(base, head, opts) then return nil end
  open_review()
  return require("reviewer.core").step
end

-- Branch names of a repository: remote branches without the remote prefix,
-- then local branches that are not on the remote.
function M.branches(repo)
  local out = require("reviewer.git").run({ "for-each-ref", "--format=%(refname:short)", "refs/remotes/" .. repo.remote, "refs/heads" }, repo.root) or ""
  local seen, list = {}, {}
  for _, r in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local name = r:gsub("^" .. vim.pesc(repo.remote) .. "/", "")
    if name ~= "HEAD" and name ~= repo.remote and not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  table.sort(list)
  return list
end

-- Choose the branch to review, then the branch to compare it with.
function M.pick_review()
  ensure_setup()
  local core = require("reviewer.core")
  local repo = core.repo_here() or core.project
  if not repo then return require("reviewer.ui").notify("not inside a git repository", vim.log.levels.ERROR) end
  local branches = M.branches(repo)
  vim.ui.select(branches, { prompt = "Branch to review" }, function(head)
    if not head then return end
    vim.schedule(function()
      local bases = vim.tbl_filter(function(b) return b ~= head end, branches)
      table.sort(bases, function(a, b)
        if a == repo.base then return true elseif b == repo.base then return false end
        return a < b
      end)
      vim.ui.select(bases, { prompt = "Compare " .. head .. " with" }, function(base)
        if base then vim.schedule(function() M.start_review(base, head) end) end
      end)
    end)
  end)
end

-- :Review [base] [head]
--   two names: review head compared with base
--   one name:  review it compared with the default base (or an id "base..head")
--   none:      continue the last review, or choose the branches
function M.start(args)
  ensure_setup()
  if type(args) == "string" then args = vim.split(args, "%s+", { trimempty = true }) end
  args = args or {}
  local core, ui = require("reviewer.core"), require("reviewer.ui")
  if #args >= 2 then return M.start_review(args[1], args[2]) end
  local repo = core.repo_here()
  if not repo then return ui.notify("not inside a git repository", vim.log.levels.ERROR) end
  if #args == 1 then
    if args[1]:find("%.%.") then return M.start_review(args[1]) end
    return M.start_review(repo.base, args[1])
  end
  local lb, lh = core.last(repo)
  if not lb then return M.pick_review() end
  vim.ui.select({ "Continue " .. lb .. " → " .. lh, "Review other branches" }, { prompt = "Review" }, function(c)
    if not c then return end
    vim.schedule(function()
      if c:match("^Continue") then M.start_review(lb, lh) else M.pick_review() end
    end)
  end)
end

local function need_review()
  ensure_setup()
  local core = require("reviewer.core")
  if core.step then return true end
  M.start()
  return false
end
local need_project = need_review

M.commands = {
  browse = function(dir) if need_project() then require("reviewer.browser").open({ dir = dir ~= "" and dir or nil }) end end,
  split = function() if need_project() then require("reviewer.split").toggle() end end,
  commits = function() if need_project() then require("reviewer.browser").commits() end end,
  next = function() if need_project() then require("reviewer.review").move(1) end end,
  prev = function() if need_project() then require("reviewer.review").move(-1) end end,
  next_unread = function() if need_project() then require("reviewer.review").move(1, true) end end,
  read = function() if need_project() then require("reviewer.review").toggle_read() end end,
  edit = function() if need_project() then require("reviewer.review").unlock() end end,
  read_next = function() if need_project() then require("reviewer.review").read_next() end end,
  explain = function(force) if need_project() then require("reviewer.review").explain(force) end end,
  comments = function() if need_project() then require("reviewer.review").toggle_comments() end end,
  keys = function() if need_project() then require("reviewer.keybar").toggle() end end,
  about = function() if need_project() then require("reviewer.review").about() end end,
  ask = function(l1, l2) if need_project() then require("reviewer.ask").ask_here(l1, l2) end end,
  asks = function() if need_project() then require("reviewer.ask").list() end end,
  quiz = function(arg) if need_project() then require("reviewer.quiz").open(arg) end end,
  progress = function() if need_project() then require("reviewer.progress").open() end end,
  prepare = function(args, bang) if need_project() then require("reviewer.prepare").command(args, bang) end end,
  overview = function() if need_project() then require("reviewer.prepare").show_overview() end end,
  fetch = function()
    if not need_project() then return end
    local core, git, ui = require("reviewer.core"), require("reviewer.git"), require("reviewer.ui")
    ui.notify("fetching " .. core.project.remote .. "…")
    local _, err = git.fetch(core.project)
    if err then return ui.notify("fetch failed: " .. err, vim.log.levels.ERROR) end
    -- same branches, maybe new commits: rebuild the review and its checkout
    local base, head = core.step.base_branch, core.step.branch
    core.forget_buffers()
    core.step = nil
    M.start_review(base, head)
    ui.notify("fetched; the review now shows the latest commits of " .. head)
  end,
  clean = function()
    ensure_setup()
    local core, git, ui = require("reviewer.core"), require("reviewer.git"), require("reviewer.ui")
    local repo = core.project or core.repo_here()
    if not repo then return ui.notify("not inside a git repository", vim.log.levels.ERROR) end
    if not vim.uv.fs_stat(repo.worktree) then return ui.notify("no hidden checkout for " .. repo.name) end
    vim.ui.select({ "Yes, remove it", "No" }, { prompt = "Remove the hidden checkout " .. repo.worktree .. "? (your progress is kept)" }, function(c)
      if not (c and c:match("^Yes")) then return end
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          if name:sub(1, #repo.worktree + 1) == repo.worktree .. "/" then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        end
        if core.step then core.step._dir = nil end
        local ok, err = git.remove_worktree(repo)
        ui.notify(ok and ("removed " .. repo.worktree) or ("could not remove it: " .. tostring(err)), ok and nil or vim.log.levels.ERROR)
      end)
    end)
  end,
}

return M
