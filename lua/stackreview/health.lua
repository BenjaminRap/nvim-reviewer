local M = {}

function M.check()
  local h = vim.health
  local config = require("stackreview.config")
  h.start("stackreview.nvim")
  if vim.fn.has("nvim-0.10") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.10 or newer is needed") end
  if vim.fn.executable("git") == 1 then h.ok("git found") else h.error("git not found") end
  local cmd = config.options.claude.cmd
  if vim.fn.executable(cmd) == 1 then h.ok("Claude Code found: " .. vim.fn.exepath(cmd))
  else h.warn("'" .. cmd .. "' not found: comments, questions and open-answer grading will not work") end
  local names = config.project_names()
  if #names == 0 then h.warn("no project configured; see the README") end
  local git = require("stackreview.git")
  for _, name in ipairs(names) do
    local p = config.project(name)
    h.start("project " .. name)
    if vim.uv.fs_stat(p.root) then h.ok("root " .. p.root) else h.error("root not found: " .. p.root) end
    for _, s in ipairs(p.steps) do
      if git.rev(p, s.head_ref) then h.ok(("step %s: %s..%s"):format(s.id, s.base_ref, s.head_ref))
      else h.error(("step %s: unknown ref %s (run :ReviewFetch)"):format(s.id, s.head_ref)) end
    end
    local quizzes = vim.fn.glob(p.quiz_dir .. "/quiz-*.json", false, true)
    if #quizzes > 0 then h.ok(#quizzes .. " quiz file(s) in " .. p.quiz_dir) else h.info("no quiz files in " .. p.quiz_dir) end
    h.info("saved state: " .. p.data_dir .. "/state.json")
  end
end

return M
