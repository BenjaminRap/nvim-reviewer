-- A throwaway git repository with a fake remote, used by every test.
--   main:     src/app.ts, src/old.ts, src/name.ts, README.md
--   feature:  src/app.ts modified, src/new.ts added, src/old.ts deleted,
--             src/name.ts renamed to src/renamed.ts, package-lock.json added (generated)
-- Both branches are pushed to `origin`; the clone stays on `main`.
local M = {}

local function git(args, cwd)
  local env = { GIT_AUTHOR_NAME = "Test", GIT_AUTHOR_EMAIL = "test@example.com", GIT_COMMITTER_NAME = "Test",
    GIT_COMMITTER_EMAIL = "test@example.com", GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" }
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, env = env, text = true }):wait()
  assert(res.code == 0, "git " .. table.concat(args, " ") .. ": " .. (res.stderr or ""))
  return res.stdout
end
M.git = git

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

function M.create()
  local base = vim.fn.tempname()
  local origin, work = base .. "/origin.git", base .. "/demo"
  vim.fn.mkdir(base, "p")
  git({ "init", "--bare", "-q", "-b", "main", origin })
  git({ "clone", "-q", origin, work })
  git({ "checkout", "-q", "-b", "main" }, work)
  write(work .. "/src/app.ts", { "const a = 1", "const b = 2", "const c = 3", "export { a, b, c }" })
  write(work .. "/src/old.ts", { "export const old = true" })
  write(work .. "/src/name.ts", { "export const name = 'x'", "export const other = 1", "export const third = 2" })
  write(work .. "/README.md", { "# demo" })
  git({ "add", "-A" }, work)
  git({ "commit", "-q", "-m", "Initial files" }, work)
  git({ "push", "-q", "origin", "main" }, work)
  git({ "checkout", "-q", "-b", "feature" }, work)
  write(work .. "/src/app.ts", { "const a = 1", "const b = 20", "const c = 3", "const d = 4", "export { a, b, c, d }" })
  write(work .. "/src/new.ts", { "export const fresh = 1", "export const more = 2" })
  git({ "add", "-A" }, work)
  git({ "commit", "-q", "-m", "Changed app and added new" }, work)
  git({ "rm", "-q", "src/old.ts" }, work)
  git({ "mv", "src/name.ts", "src/renamed.ts" }, work)
  write(work .. "/package-lock.json", { "{}" })
  git({ "add", "-A" }, work)
  git({ "commit", "-q", "-m", "Removed old, renamed name, added a lockfile" }, work)
  git({ "push", "-q", "origin", "feature" }, work)
  git({ "checkout", "-q", "main" }, work)
  M.root, M.base = work, base
  vim.fn.chdir(work)
  return work
end

-- Start a review of feature compared with main, with the plugin set up.
function M.review(opts)
  if not M.root then M.create() end
  vim.fn.chdir(M.root)
  require("reviewer").setup(vim.tbl_deep_extend("force", { deps = { install = false }, ai = { on_start = "never" }, key_hints = false }, opts or {}))
  return require("reviewer").start_review("main", "feature")
end

-- Lines of the current buffer without the hidden ids of the browser.
function M.shown()
  local t = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do t[#t + 1] = (l:gsub("^/%d+ ", "")) end
  return t
end

-- Put the cursor on the first line containing `text`.
function M.cursor_on(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("no line containing " .. text)
end

function M.press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- Tick the checkbox on the current line ("x" or " ").
function M.tick(mark)
  local l = vim.api.nvim_win_get_cursor(0)[1]
  local s = vim.api.nvim_get_current_line():find("%[.%]")
  vim.api.nvim_buf_set_text(0, l - 1, s, l - 1, s + 1, { mark or "x" })
end

return M
