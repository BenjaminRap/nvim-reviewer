-- A small test runner: describe/it/expect, one line per test, exit code 1 on failure.
local M = { tests = {}, prefix = {} }

function _G.describe(name, fn)
  table.insert(M.prefix, name)
  fn()
  table.remove(M.prefix)
end

function _G.it(name, fn)
  M.tests[#M.tests + 1] = { name = table.concat(M.prefix, " › ") .. " › " .. name, fn = fn }
end

local function fmt(v) return type(v) == "string" and ("%q"):format(v) or vim.inspect(v) end

function _G.expect(actual)
  return {
    equal = function(expected, what)
      if not vim.deep_equal(actual, expected) then
        error(("%sexpected %s, got %s"):format(what and (what .. ": ") or "", fmt(expected), fmt(actual)), 2)
      end
    end,
    truthy = function(what) if not actual then error((what or "value") .. " should be true, got " .. fmt(actual), 2) end end,
    falsy = function(what) if actual then error((what or "value") .. " should be false, got " .. fmt(actual), 2) end end,
    contains = function(needle, what)
      if type(actual) ~= "string" or not actual:find(needle, 1, true) then
        error(("%s%s should contain %s"):format(what and (what .. ": ") or "", fmt(actual), fmt(needle)), 2)
      end
    end,
  }
end

function M.run()
  local files = vim.fn.glob(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/*_spec.lua", false, true)
  table.sort(files)
  local only = vim.env.SPEC
  for _, f in ipairs(files) do
    if not only or f:find(only, 1, true) then dofile(f) end
  end
  local failed = 0
  for _, t in ipairs(M.tests) do
    local ok, err = xpcall(t.fn, debug.traceback)
    if ok then
      io.stdout:write("ok    " .. t.name .. "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      ") .. "\n")
    end
  end
  io.stdout:write(("\n%d tests, %d failed\n"):format(#M.tests, failed))
  vim.cmd(failed > 0 and "cquit 1" or "qall!")
end

return M
