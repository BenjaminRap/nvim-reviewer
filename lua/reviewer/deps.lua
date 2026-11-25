-- Installs the dependencies of the hidden checkout, so that the LSP finds the
-- types of external packages. Never touches your own checkout.
-- Reinstalls only when the lockfile changes. Install scripts are skipped by default,
-- so no code from the reviewed branch runs during the install.
local config = require("reviewer.config")
local ui = require("reviewer.ui")

local M = { running = {} }

local MARKER = "node_modules/.reviewer-lock"

-- Install command for the lockfile found in `dir`, or nil.
function M.detect(dir)
  local o = config.options.deps or {}
  local skip = o.ignore_scripts ~= false
  local candidates = {
    { file = "package-lock.json", cmd = { "npm", "ci", "--no-audit", "--no-fund" }, flag = "--ignore-scripts" },
    { file = "pnpm-lock.yaml", cmd = { "pnpm", "install", "--frozen-lockfile" }, flag = "--ignore-scripts" },
    { file = "yarn.lock", cmd = { "yarn", "install", "--frozen-lockfile" }, flag = "--ignore-scripts" },
  }
  for _, c in ipairs(candidates) do
    if vim.uv.fs_stat(dir .. "/" .. c.file) then
      local cmd = vim.deepcopy(o.cmd or c.cmd)
      if skip and not o.cmd then cmd[#cmd + 1] = c.flag end
      return { lockfile = c.file, cmd = cmd }
    end
  end
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- True when node_modules matches the current lockfile.
function M.up_to_date(dir, lockfile)
  local lock = read(dir .. "/" .. lockfile)
  return lock ~= nil and read(dir .. "/" .. MARKER) == vim.fn.sha256(lock)
end

-- Restart the LSP clients whose root is inside `dir`, so they see the new packages.
local function restart_lsp(dir)
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients()) do
    local root = c.config and c.config.root_dir
    if root and vim.fs.normalize(root):sub(1, #dir) == dir then names[c.name] = true end
  end
  local list = vim.tbl_keys(names)
  if #list == 0 then return end
  if vim.fn.exists(":LspRestart") == 2 then
    vim.cmd("silent! LspRestart " .. table.concat(list, " "))
  else
    ui.notify("restart your LSP (" .. table.concat(list, ", ") .. ") to load the new packages")
  end
end

-- Install in `dir` (the hidden checkout) when needed. on_done(ok) is optional.
function M.ensure(repo, dir, on_done)
  local o = config.options.deps or {}
  if o.install == false or o.install == "never" then return end
  if dir ~= repo.worktree then return end -- never in your own checkout
  local d = M.detect(dir)
  if not d or M.up_to_date(dir, d.lockfile) then return end
  if M.running[dir] then return end
  if vim.fn.executable(d.cmd[1]) ~= 1 then
    return ui.notify(("'%s' not found: the LSP will not have the types of external packages"):format(d.cmd[1]), vim.log.levels.WARN)
  end
  M.running[dir] = true
  ui.notify(("installing dependencies in the hidden checkout (%s)…"):format(table.concat(d.cmd, " ")))
  vim.system(d.cmd, { cwd = dir, text = true }, function(res)
    vim.schedule(function()
      M.running[dir] = nil
      if res.code == 0 then
        local lock = read(dir .. "/" .. d.lockfile)
        local f = io.open(dir .. "/" .. MARKER, "w")
        if f and lock then f:write(vim.fn.sha256(lock)) ; f:close() end
        ui.notify("dependencies installed; the LSP now sees external packages")
        restart_lsp(dir)
      else
        local err = vim.trim(res.stderr or ""):sub(-400)
        ui.notify("dependency install failed: " .. err, vim.log.levels.WARN)
      end
      if on_done then on_done(res.code == 0) end
    end)
  end)
end

return M
