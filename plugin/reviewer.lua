if vim.g.loaded_reviewer then return end
vim.g.loaded_reviewer = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("nvim-reviewer needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

-- One command: `:Review [base] head` starts a review, `:Review <subcommand>`
-- does the rest (`:Review <Tab>` lists them; see :help reviewer-commands).
vim.api.nvim_create_user_command("Review", function(o) require("reviewer").command(o) end, {
  nargs = "*", bang = true, range = true,
  desc = "Review a branch (:Review [base] head) or run a subcommand (:Review quiz, :Review progress, ...)",
  complete = function(lead, line) return require("reviewer").complete(lead, line) end,
})
