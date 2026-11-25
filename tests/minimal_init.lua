-- Neovim setup for the tests: only this plugin, isolated data and cache folders
-- (set by tests/run.sh), and no prompt ever waits for input.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
vim.cmd("runtime plugin/reviewer.lua")
vim.notify = function() end
vim.ui.select = function(_, _, cb) cb(nil) end
