-- Small window helpers: floats, a multi-line input box, text wrapping.
local M = {}

function M.wrap(text, width)
  local out = {}
  for para in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      out[#out + 1] = ""
    else
      local line, indent = "", para:match("^(%s*[-*•]?%s*)") or ""
      for word in para:gmatch("%S+") do
        if line == "" then line = word
        elseif vim.fn.strdisplaywidth(line .. " " .. word) > width then
          out[#out + 1] = line
          line = string.rep(" ", #indent) .. word
        else line = line .. " " .. word end
      end
      out[#out + 1] = line
    end
  end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

function M.float(opts)
  local fc = require("reviewer.config").options.float
  local function size(v, total) return v <= 1 and math.floor(total * v) or v end
  local width = opts.width or size(fc.width or 0.8, vim.o.columns)
  local height = opts.height or size(fc.height or 0.8, vim.o.lines)
  width, height = math.min(width, vim.o.columns - 4), math.min(height, vim.o.lines - 4)
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local wcfg = {
    relative = "editor", style = "minimal", border = fc.border or "rounded",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col = math.floor((vim.o.columns - width) / 2),
  }
  if opts.title then wcfg.title, wcfg.title_pos = " " .. opts.title .. " ", "center" end
  if opts.footer then wcfg.footer, wcfg.footer_pos = " " .. opts.footer .. " ", "center" end
  local win = vim.api.nvim_open_win(buf, true, wcfg)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  if opts.filetype then vim.bo[buf].filetype = opts.filetype end
  return buf, win
end

function M.set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

-- Read-only markdown text in a float; q or <Esc> closes it.
function M.show(title, lines, opts)
  opts = opts or {}
  local keys = require("reviewer.keys")
  local close = keys.opts("float").close
  local buf, win = M.float({ title = title, filetype = "markdown", width = opts.width, height = opts.height, footer = opts.footer or (keys.labels(close) .. " close") })
  M.set_lines(buf, lines)
  keys.map(buf, "n", close, function() pcall(vim.api.nvim_win_close, win, true) end, "close")
  return buf, win
end

-- Multi-line input. <C-s> (normal or insert) or <CR> in normal mode submits; q / <Esc> cancels.
function M.input(opts, on_submit)
  local buf, win = M.float({
    title = opts.title, filetype = opts.filetype or "markdown",
    width = opts.width or math.min(100, math.floor(vim.o.columns * 0.7)), height = opts.height or 12,
    footer = (function()
      local keys, k = require("reviewer.keys"), require("reviewer.keys").opts("input")
      return ("%s or %s save · %s cancel"):format(keys.label(k.submit), keys.label(k.submit_normal), keys.label(k.cancel))
    end)(),
  })
  vim.bo[buf].buftype = "nofile"
  if opts.header then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.header)
  end
  local start = opts.header and #opts.header or 0
  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(buf, start, -1, false, vim.split(opts.text, "\n"))
  elseif opts.header then
    vim.api.nvim_buf_set_lines(buf, start, -1, false, { "" })
  end
  local done = false
  local function submit()
    if done then return end
    done = true
    local lines = vim.api.nvim_buf_get_lines(buf, start, -1, false)
    pcall(vim.api.nvim_win_close, win, true)
    vim.cmd("stopinsert")
    local text = vim.trim(table.concat(lines, "\n"))
    if text ~= "" then on_submit(text) end
  end
  local function cancel()
    done = true
    pcall(vim.api.nvim_win_close, win, true)
  end
  local keys = require("reviewer.keys")
  local k = keys.opts("input")
  keys.map(buf, { "n", "i" }, k.submit, submit, "save")
  keys.map(buf, "n", k.submit_normal, submit, "save")
  keys.map(buf, "n", k.cancel, cancel, "cancel")
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.cmd("startinsert!")
end

function M.notify(msg, level) vim.notify("reviewer: " .. msg, level or vim.log.levels.INFO) end

function M.fmt_date(iso)
  if not iso then return "" end
  local y, m, d, H, Mi = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+)")
  if not y then return iso end
  local t = os.time({ year = y, month = m, day = d, hour = H, min = Mi })
  -- stored in UTC; shift to local time
  local offset = os.time() - os.time(os.date("!*t"))
  return os.date("%b %d %H:%M", t + offset)
end

return M
