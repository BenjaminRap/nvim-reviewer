if vim.g.loaded_stackreview then return end
vim.g.loaded_stackreview = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("stackreview.nvim needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

local function c() return require("stackreview").commands end
local cmd = vim.api.nvim_create_user_command

cmd("Review", function(o) require("stackreview").start(o.args) end, {
  nargs = "?", desc = "Start reviewing a project's branch stack",
  complete = function() return require("stackreview.config").project_names() end,
})
cmd("ReviewStep", function(o) c().step(o.args) end, { nargs = 1, desc = "Go to a review step" })
cmd("ReviewPanel", function() c().panel() end, { desc = "Toggle the review file panel" })
cmd("ReviewNext", function() c().next() end, { desc = "Open the next file of the step" })
cmd("ReviewPrev", function() c().prev() end, { desc = "Open the previous file of the step" })
cmd("ReviewNextUnread", function() c().next_unread() end, { desc = "Open the next unread file" })
cmd("ReviewRead", function() c().read() end, { desc = "Toggle the read mark of the current file" })
cmd("ReviewReadNext", function() c().read_next() end, { desc = "Mark read and open the next unread file" })
cmd("ReviewExplain", function(o) c().explain(o.bang) end, { bang = true, desc = "Claude's comments on this file (! writes them again)" })
cmd("ReviewComments", function() c().comments() end, { desc = "Show or hide Claude's comments" })
cmd("ReviewAbout", function() c().about() end, { desc = "Summary and commits of the current file" })
cmd("ReviewNote", function(o) c().note(o.line1, o.line2) end, { range = true, desc = "Add a note on the current line or range" })
cmd("ReviewNotes", function() c().notes() end, { desc = "List, open, resolve or delete notes" })
cmd("ReviewAsk", function(o) c().ask(o.range > 0 and o.line1 or nil, o.range > 0 and o.line2 or nil) end, { range = true, desc = "Ask Claude about this file or the selected lines" })
cmd("ReviewAsks", function() c().asks() end, { desc = "Questions you asked Claude, with answers" })
cmd("ReviewQuiz", function(o) c().quiz(o.args) end, {
  nargs = "?", desc = "Take a quiz: step number, final, or mistakes",
  complete = function()
    local ok, quiz = pcall(require, "stackreview.quiz")
    local list = ok and quiz.ids() or {}
    for i, id in ipairs(list) do list[i] = id:gsub("^step", "") end
    list[#list + 1] = "mistakes"
    return list
  end,
})
cmd("ReviewProgress", function() c().progress() end, { desc = "Files read, quiz results, mistakes, questions, notes" })
cmd("ReviewPrepare", function(o) c().prepare(o.fargs, o.bang) end, {
  nargs = "*", bang = true, desc = "Prepare a step in the background: overview, comments on every file, quiz",
  complete = function(_, line)
    local n = #vim.split(line, "%s+") - 1
    if n <= 1 then
      local list = { "final", "all", "stop" }
      local ok, config = pcall(require, "stackreview.config")
      for _, name in ipairs(ok and config.project_names() or {}) do
        for i = 1, #config.project(name).steps do list[#list + 1] = tostring(i) end
        break
      end
      return list
    end
    return { "overview", "comments", "quiz" }
  end,
})
cmd("ReviewOverview", function() c().overview() end, { desc = "Overview of the current step" })
cmd("ReviewFetch", function() c().fetch() end, { desc = "git fetch, then move the step folders to their branch heads" })
