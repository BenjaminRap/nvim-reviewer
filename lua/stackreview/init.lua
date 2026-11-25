-- stackreview.nvim: review a stack of branches step by step, file by file,
-- with Claude's comments, notes, quizzes and saved progress.
local config = require("stackreview.config")

local M = {}

local did_setup = false

function M.setup(opts)
  config.setup(opts)
  require("stackreview.render").setup_highlights()
  if did_setup then return end
  did_setup = true
  local group = vim.api.nvim_create_augroup("stackreview", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() require("stackreview.render").setup_highlights() end })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      local core = require("stackreview.core")
      if not core.project then return end
      local review = require("stackreview.review")
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(win).relative == "" and win ~= require("stackreview.panel").win then review.last_win = win end
      review.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(ev) require("stackreview.core").buffers[ev.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function() if require("stackreview.core").project then require("stackreview.render").draw_all() end end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() require("stackreview.state").flush_all() end })
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

-- :Review [project]
function M.start(name)
  ensure_setup()
  local core = require("stackreview.core")
  if not core.activate(name ~= "" and name or nil) then return end
  require("stackreview.git").clear_cache()
  require("stackreview.quiz").reload()
  require("stackreview.panel").open()
  -- overlays for files already open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then require("stackreview.review").attach(buf) end
  end
  vim.schedule(function() require("stackreview.prepare").offer_on_start() end)
end

local function need_project()
  ensure_setup()
  local core = require("stackreview.core")
  if core.project then return true end
  M.start()
  return core.project ~= nil
end

M.commands = {
  step = function(arg) if need_project() then require("stackreview.core").set_step(arg) ; require("stackreview.panel").open() end end,
  panel = function() if need_project() then require("stackreview.panel").toggle() end end,
  next = function() if need_project() then require("stackreview.review").move(1) end end,
  prev = function() if need_project() then require("stackreview.review").move(-1) end end,
  next_unread = function() if need_project() then require("stackreview.review").move(1, true) end end,
  read = function() if need_project() then require("stackreview.review").toggle_read() end end,
  read_next = function() if need_project() then require("stackreview.review").read_next() end end,
  explain = function(force) if need_project() then require("stackreview.review").explain(force) end end,
  comments = function() if need_project() then require("stackreview.review").toggle_comments() end end,
  about = function() if need_project() then require("stackreview.review").about() end end,
  note = function(l1, l2) if need_project() then require("stackreview.notes").add_here(l1, l2) end end,
  notes = function() if need_project() then require("stackreview.notes").list() end end,
  ask = function(l1, l2) if need_project() then require("stackreview.ask").ask_here(l1, l2) end end,
  asks = function() if need_project() then require("stackreview.ask").list() end end,
  quiz = function(arg) if need_project() then require("stackreview.quiz").open(arg) end end,
  progress = function() if need_project() then require("stackreview.progress").open() end end,
  prepare = function(args, bang) if need_project() then require("stackreview.prepare").command(args, bang) end end,
  overview = function() if need_project() then require("stackreview.prepare").show_overview() end end,
  fetch = function()
    if not need_project() then return end
    local core, git, ui = require("stackreview.core"), require("stackreview.git"), require("stackreview.ui")
    ui.notify("fetching " .. core.project.remote .. "…")
    local _, err = git.fetch(core.project)
    if err then return ui.notify("fetch failed: " .. err, vim.log.levels.ERROR) end
    git.clear_cache()
    local report = git.update_worktrees(core.project)
    for buf in pairs(core.buffers) do core.buffers[buf] = nil end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_clear_namespace(buf, require("stackreview.render").ns, 0, -1)
        require("stackreview.review").attach(buf)
      end
    end
    core.changed()
    ui.notify("fetched. " .. (#report > 0 and table.concat(report, "; ") or "no step folders to move"))
  end,
}

return M
