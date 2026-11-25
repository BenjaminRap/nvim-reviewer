-- Key helpers: every key option can be a string, a list of strings, or false.
local M = {}

function M.list(lhs)
  if not lhs or lhs == "" then return {} end
  if type(lhs) == "string" then return { lhs } end
  return lhs
end

-- First key of an option, for display ("" when disabled).
function M.label(lhs) return M.list(lhs)[1] or "" end

-- All keys of an option joined for help texts.
function M.labels(lhs) return table.concat(M.list(lhs), " ") end

function M.map(buf, modes, lhs, fn, desc)
  for _, k in ipairs(M.list(lhs)) do
    vim.keymap.set(modes, k, fn, { buffer = buf, silent = true, nowait = true, desc = "Reviewer: " .. desc })
  end
end

function M.opts(section) return require("reviewer.config").options.keymaps[section] or {} end

return M
