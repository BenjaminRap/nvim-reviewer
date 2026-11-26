-- A bar at the bottom of the screen listing the keys of the current review
-- buffer (reviewed file, browser or quiz), like lazygit. It is a real window,
-- so it never hides code; focus never stays in it.
local config = require("reviewer.config")
local keys = require("reviewer.keys")

local M = { win = nil, buf = nil, kind = nil, hidden = false }
local ns = vim.api.nvim_create_namespace("reviewer_keybar")

-- { section, option name, short label }; a literal key instead of an option name is a string in [ ].
local ENTRIES = {
  file = {
    { "file", "next_change", "next change" }, { "file", "prev_change", "prev change" },
    { "file", "next_file", "next file" }, { "file", "prev_file", "prev file" },
    { "file", "toggle_read", "read" }, { "file", "read_next", "read + next" },
    { "file", "browse", "files" }, { "file", "ask", "ask Claude (or lines)" },
    { "file", "explain", "write comments" }, { "file", "comments_style", "boxes / markers" },
    { "file", "about", "about the file" }, { "file", "toggle_split", "side by side" },
    { "file", "help", "all keys" },
  },
  browser = {
    { "browser", "open", "open" }, { "browser", "parent", "up" }, { "browser", "root", "root" },
    { "[x] :w", nil, "mark read" }, { "browser", "toggle_view", "reading order" },
    { "browser", "commits", "commits" }, { "browser", "explain", "comment file" },
    { "browser", "prepare", "prepare" }, { "browser", "overview", "overview" },
    { "browser", "quiz", "quiz" }, { "browser", "progress", "progress" },
    { "browser", "new_review", "other branches" }, { "browser", "help", "all keys" },
  },
  quiz = {
    { "quiz", "choices", "pick" }, { "quiz", "check", "check / next" }, { "quiz", "answer", "answer" },
    { "quiz", "dont_know", "don't know" }, { "quiz", "next", "next" }, { "quiz", "prev", "previous" },
    { "quiz", "hint", "hint" }, { "quiz", "explain", "ask why" }, { "quiz", "refs", "open code" },
    { "quiz", "retry", "retry" }, { "quiz", "overview", "results" }, { "quiz", "close", "close" },
  },
}

local LONG = {
  file = {
    next_change = "next change", prev_change = "previous change", next_file = "next file of the review",
    prev_file = "previous file of the review", toggle_read = "toggle the read mark",
    read_next = "mark read and open the next unread file", browse = "review browser on this folder",
    ask = "ask Claude about the file (visual: about the lines)", explain = "write Claude's comments on this file",
    comments_style = "Claude's comments as boxes / as markers shown on hover", about = "summary, changes and commits of the file",
    toggle_split = "inline changes / side by side", help = "this help",
  },
}

local function label_of(section, name)
  if not name then return section end
  local v = keys.opts(section)[name]
  if section == "quiz" and name == "choices" then return (v and v ~= "") and (v:sub(1, 1) .. "-" .. v:sub(-1)) or "" end
  if section == "quiz" and name == "refs" then
    local l = keys.list(v)
    return #l > 1 and (l[1] .. "-" .. l[#l]) or (l[1] or "")
  end
  return (keys.labels(v):gsub(" ", "/"))
end

-- "<leader>rr" is long: show the leader itself ("␣rr" for a space).
local function short(k)
  local leader = vim.g.mapleader or "\\"
  leader = leader == " " and "␣" or leader
  return (k:gsub("<[Ll]eader>", function() return leader end))
end

-- Kind of review buffer shown in a window, or nil.
local function kind_of(buf)
  if require("reviewer.core").buffers[buf] then return "file" end
  if require("reviewer.browser").is_browser(buf) then return "browser" end
  if require("reviewer.quiz").buf == buf then return "quiz" end
end

local function chunks(kind, width)
  local lines, hls, line, col = { "" }, {}, "", 0
  for _, e in ipairs(ENTRIES[kind]) do
    local k = short(label_of(e[1], e[2]))
    if k ~= "" then
      local item = " " .. k .. " " .. e[3]
      local sep = line == "" and "" or "  "
      if line ~= "" and vim.fn.strdisplaywidth(line .. sep .. item) > width then
        lines[#lines] = line
        lines[#lines + 1] = ""
        line, sep = "", ""
      end
      local start = #line + #sep
      line = line .. sep .. item
      hls[#hls + 1] = { #lines - 1, start + 1, start + 1 + #k, "ReviewerKey" }
      hls[#hls + 1] = { #lines - 1, start + 1 + #k, #line, "ReviewerKeyDesc" }
    end
  end
  lines[#lines] = line
  return lines, hls
end

local function close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then pcall(vim.api.nvim_win_close, M.win, true) end
  M.win, M.kind = nil, nil
end

local function normal_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= M.win and vim.api.nvim_win_get_config(w).relative == "" then n = n + 1 end
  end
  return n
end

function M.update()
  if not config.options.key_hints or M.hidden or not require("reviewer.core").project then return close() end
  local cur = vim.api.nvim_get_current_win()
  if cur == M.win then return end
  local kind = kind_of(vim.api.nvim_get_current_buf())
  -- in another float (help, answers), keep the bar as it is
  if not kind and vim.api.nvim_win_get_config(cur).relative ~= "" then return end
  if not kind then return close() end
  if M.win and (not vim.api.nvim_win_is_valid(M.win) or vim.api.nvim_win_get_tabpage(M.win) ~= vim.api.nvim_get_current_tabpage()) then close() end

  local lines, hls = chunks(kind, vim.o.columns - 1)
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.buf].bufhidden = "hide"
    vim.bo[M.buf].filetype = "reviewer-keys"
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  if not M.win then
    M.win = vim.api.nvim_open_win(M.buf, false, {
      split = "below", win = -1, height = #lines, style = "minimal", focusable = false, noautocmd = true,
    })
    vim.wo[M.win].winfixheight = true
    vim.wo[M.win].winfixbuf = true
    vim.wo[M.win].wrap = false
    vim.wo[M.win].winhighlight = "Normal:ReviewerKeyBar,EndOfBuffer:ReviewerKeyBar"
  elseif vim.api.nvim_win_get_height(M.win) ~= #lines then
    vim.api.nvim_win_set_height(M.win, #lines)
  end
  M.kind = kind
end

function M.toggle()
  if not config.options.key_hints then config.options.key_hints, M.hidden = true, false
  else M.hidden = not M.hidden end
  M.update()
end

-- Every key of a kind of buffer, in a float.
function M.help(kind)
  local out = {}
  for _, e in ipairs(ENTRIES[kind] or {}) do
    local k = label_of(e[1], e[2])
    if k ~= "" then out[#out + 1] = ("%-14s %s"):format(k, (LONG[kind] and e[2] and LONG[kind][e[2]]) or e[3]) end
  end
  vim.list_extend(out, { "", "Commands: :Review :ReviewBrowse :ReviewQuiz :ReviewProgress :ReviewAsks", ":ReviewKeys shows or hides the key bar." })
  require("reviewer.ui").show("Keys", out, { width = 80, height = #out + 2 })
end

function M.setup(group)
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "VimResized" }, {
    group = group,
    callback = function()
      -- focus never stays in the bar (<C-w>j can still reach a non-focusable split)
      if M.win and vim.api.nvim_get_current_win() == M.win then
        vim.schedule(function() if vim.api.nvim_get_current_win() == M.win then vim.cmd("wincmd p") end end)
        return
      end
      vim.schedule(M.update)
    end,
  })
  -- quitting the last window must not leave the bar alone on screen
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function() if M.win and normal_wins() <= 1 then close() end end,
  })
end

return M
