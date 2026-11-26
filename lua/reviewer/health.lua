local M = {}

function M.check()
  local h = vim.health
  local config = require("reviewer.config")
  h.start("nvim-reviewer")
  if vim.fn.has("nvim-0.10") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.10 or newer is needed") end
  if vim.fn.executable("git") == 1 then h.ok("git found") else h.error("git not found") end
  local cmd = config.options.claude.cmd
  if vim.fn.executable(cmd) == 1 then h.ok("Claude Code found: " .. vim.fn.exepath(cmd))
  else h.warn("'" .. cmd .. "' not found: comments, questions and open-answer grading will not work") end

  local core = require("reviewer.core")
  local repo = core.repo_here()
  h.start("repository of the current directory")
  if not repo then return h.info("not inside a git repository; :Review works from inside one") end
  h.ok(("%s (%s)"):format(repo.name, repo.root))
  local base_ref = core.resolve(repo, repo.base)
  if base_ref then h.ok("default base: " .. base_ref)
  else h.warn(("default base '%s' not found; set `base` in the options or give two branches to :Review"):format(repo.base)) end
  local base, head = core.last(repo)
  if base then
    local r = core.review(repo, base, head)
    if r then h.ok(("last review: %s (%s..%s)"):format(r.label, r.base_ref, r.head_ref))
    else h.warn(("last review %s → %s: a branch is missing (run :Review fetch?)"):format(base, head)) end
  end
  if vim.uv.fs_stat(repo.worktree) then h.info("hidden checkout: " .. repo.worktree .. " (:Review clean removes it)")
  else h.info("no hidden checkout yet (made when the reviewed branch is not the one checked out)") end
  local quizzes = vim.fn.glob(repo.quiz_dir .. "/quiz-*.json", false, true)
  h.info(#quizzes .. " quiz file(s) in " .. repo.quiz_dir)
  h.info("saved state: " .. repo.data_dir .. "/state.json")
end

return M
