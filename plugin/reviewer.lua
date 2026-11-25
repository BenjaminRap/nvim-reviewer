if vim.g.loaded_reviewer then return end
vim.g.loaded_reviewer = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("nvim-reviewer needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

local function c() return require("reviewer").commands end
local cmd = vim.api.nvim_create_user_command

cmd("Review", function(o) require("reviewer").start(o.fargs) end, {
  nargs = "*", desc = "Review a branch: :Review [base] head (no argument: continue or choose)",
  complete = function(lead)
    local ok, core = pcall(require, "reviewer.core")
    local repo = ok and core.repo_here()
    if not repo then return {} end
    return vim.tbl_filter(function(b) return b:find(lead, 1, true) == 1 end, require("reviewer").branches(repo))
  end,
})
cmd("ReviewBrowse", function(o) c().browse(o.args) end, { nargs = "?", desc = "Open the review browser (optionally on a folder)" })
cmd("ReviewNext", function() c().next() end, { desc = "Open the next file of the step" })
cmd("ReviewPrev", function() c().prev() end, { desc = "Open the previous file of the step" })
cmd("ReviewNextUnread", function() c().next_unread() end, { desc = "Open the next unread file" })
cmd("ReviewRead", function() c().read() end, { desc = "Toggle the read mark of the current file" })
cmd("ReviewEdit", function() c().edit() end, { desc = "Allow changes in the current reviewed file" })
cmd("ReviewReadNext", function() c().read_next() end, { desc = "Mark read and open the next unread file" })
cmd("ReviewExplain", function(o) c().explain(o.bang) end, { bang = true, desc = "Claude's comments on this file (! writes them again)" })
cmd("ReviewComments", function() c().comments() end, { desc = "Show or hide Claude's comments" })
cmd("ReviewAbout", function() c().about() end, { desc = "Summary and commits of the current file" })
cmd("ReviewAsk", function(o) c().ask(o.range > 0 and o.line1 or nil, o.range > 0 and o.line2 or nil) end, { range = true, desc = "Ask Claude about this file or the selected lines" })
cmd("ReviewAsks", function() c().asks() end, { desc = "Questions you asked Claude, with answers" })
cmd("ReviewQuiz", function(o) c().quiz(o.args) end, {
  nargs = "?", desc = "Quiz of the current review; `list` for another one, `mistakes` to retry them all",
  complete = function()
    return { "list", "mistakes" }
  end,
})
cmd("ReviewProgress", function() c().progress() end, { desc = "Files read, quiz results, mistakes, questions asked" })
cmd("ReviewPrepare", function(o) c().prepare(o.fargs, o.bang) end, {
  nargs = "*", bang = true, desc = "Prepare the review in the background: overview, comments on every file, quiz",
  complete = function() return { "overview", "comments", "quiz", "stop" } end,
})
cmd("ReviewOverview", function() c().overview() end, { desc = "Overview of the changes of the review" })
cmd("ReviewFetch", function() c().fetch() end, { desc = "git fetch, then show the latest commits of the reviewed branches" })
cmd("ReviewClean", function() c().clean() end, { desc = "Remove the hidden checkout of this repository" })
