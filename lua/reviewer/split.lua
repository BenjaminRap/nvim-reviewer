-- Side-by-side layout: the version before the change on the left, the reviewed
-- file on the right, compared with Neovim's own diff mode (:diffthis).
-- The inline overlay (green lines, removed lines in red) is turned off meanwhile.
local config = require("reviewer.config")
local core = require("reviewer.core")
local git = require("reviewer.git")
local ui = require("reviewer.ui")

local M = { on = nil, tabs = {} } -- tabpage -> { left_win, right_win }

function M.active()
  if M.on == nil then M.on = config.options.layout == "split" end
  return M.on
end

-- Buffer holding the version of a file before the change.
local function old_buffer(ctx)
  local f, p, s = ctx.file, ctx.project, ctx.step
  local path = f.old or f.path
  local name = ("reviewer://%s/%s/~before/%s"):format(p.name, s.id, path)
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  local content = f.status == "A" and "" or (git.show(p, s.base_ref, path) or "")
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then lines[#lines] = nil end
  ui.set_lines(buf, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
  return buf
end

local function valid(w) return w and vim.api.nvim_win_is_valid(w) end

-- Show the version before the change next to `win`, which shows the reviewed file of `ctx`.
function M.show(ctx, win)
  if not ctx or ctx.deleted then return end
  win = win or vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local t = M.tabs[tab] or {}
  local back = vim.api.nvim_get_current_win()
  if not valid(t.left_win) or t.left_win == win then
    vim.api.nvim_set_current_win(win)
    vim.cmd("leftabove vsplit")
    t.left_win = vim.api.nvim_get_current_win()
  end
  t.right_win = win
  M.tabs[tab] = t
  vim.api.nvim_win_set_buf(t.left_win, old_buffer(ctx))
  for _, w in ipairs({ t.left_win, t.right_win }) do
    vim.api.nvim_win_call(w, function() vim.cmd("diffthis") end)
  end
  vim.api.nvim_win_call(t.right_win, function() vim.cmd("diffupdate") end)
  vim.wo[t.left_win].winbar = " before: " .. (ctx.file.old or ctx.file.path):gsub("%%", "%%%%") .. " (" .. ctx.step.base_branch:gsub("%%", "%%%%") .. ")"
  if valid(back) then vim.api.nvim_set_current_win(back == t.left_win and t.right_win or back) end
end

-- Close the left window of this tab and leave diff mode.
function M.hide()
  local tab = vim.api.nvim_get_current_tabpage()
  local t = M.tabs[tab]
  if not t then return end
  if valid(t.right_win) then vim.api.nvim_win_call(t.right_win, function() vim.cmd("diffoff") end) end
  if valid(t.left_win) then pcall(vim.api.nvim_win_close, t.left_win, true) end
  M.tabs[tab] = nil
end

-- :Review split — switch between the inline overlay and side by side.
function M.toggle()
  M.on = not M.active()
  local review = require("reviewer.review")
  local ctx = core.buffers[vim.api.nvim_get_current_buf()]
  if M.on then
    if ctx then M.show(ctx, vim.api.nvim_get_current_win()) end
  else
    M.hide()
  end
  require("reviewer.render").draw_all()
  local _ = review
  ui.notify(M.on and "side by side" or "inline changes")
end

-- When a window of the side-by-side pair shows something else, close the pair.
function M.check(win, buf)
  local t = M.tabs[vim.api.nvim_get_current_tabpage()]
  if t and t.right_win == win and not core.buffers[buf] then M.hide() end
end

-- After a reviewed file is opened in `win`: keep the layout.
function M.follow(ctx, win)
  if M.active() then M.show(ctx, win) end
end

return M
