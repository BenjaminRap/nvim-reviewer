-- nvim-reviewer: review a stack of branches step by step, file by file,
-- with Claude's comments, notes, quizzes and saved progress.
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
      if vim.api.nvim_win_get_config(win).relative == "" and win ~= require("reviewer.panel").win then review.last_win = win end
      review.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(ev) require("reviewer.core").buffers[ev.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function() if require("reviewer.core").project then require("reviewer.render").draw_all() end end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() require("reviewer.state").flush_all() end })
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

-- :Review [project]
function M.start(name)
  ensure_setup()
  local core = require("reviewer.core")
  if not core.activate(name ~= "" and name or nil) then return end
  require("reviewer.git").clear_cache()
  require("reviewer.quiz").reload()
  require("reviewer.panel").open()
  -- overlays for files already open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then require("reviewer.review").attach(buf) end
  end
  vim.schedule(function() require("reviewer.prepare").offer_on_start() end)
end

local function need_project()
  ensure_setup()
  local core = require("reviewer.core")
  if core.project then return true end
  M.start()
  return core.project ~= nil
end

M.commands = {
  step = function(arg) if need_project() then require("reviewer.core").set_step(arg) ; require("reviewer.panel").open() end end,
  panel = function() if need_project() then require("reviewer.panel").toggle() end end,
  next = function() if need_project() then require("reviewer.review").move(1) end end,
  prev = function() if need_project() then require("reviewer.review").move(-1) end end,
  next_unread = function() if need_project() then require("reviewer.review").move(1, true) end end,
  read = function() if need_project() then require("reviewer.review").toggle_read() end end,
  read_next = function() if need_project() then require("reviewer.review").read_next() end end,
  explain = function(force) if need_project() then require("reviewer.review").explain(force) end end,
  comments = function() if need_project() then require("reviewer.review").toggle_comments() end end,
  about = function() if need_project() then require("reviewer.review").about() end end,
  note = function(l1, l2) if need_project() then require("reviewer.notes").add_here(l1, l2) end end,
  notes = function() if need_project() then require("reviewer.notes").list() end end,
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
    git.clear_cache()
    local report = git.update_worktrees(core.project)
    for buf in pairs(core.buffers) do core.buffers[buf] = nil end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_clear_namespace(buf, require("reviewer.render").ns, 0, -1)
        require("reviewer.review").attach(buf)
      end
    end
    core.changed()
    ui.notify("fetched. " .. (#report > 0 and table.concat(report, "; ") or "no step folders to move"))
  end,
}

return M
