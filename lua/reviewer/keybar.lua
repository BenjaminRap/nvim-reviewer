-- A bar at the bottom of the screen listing the keys of the current review
-- buffer (reviewed file, browser or quiz), like lazygit. It is a real window,
-- so it never hides code; focus never stays in it.
local config = require("reviewer.config")
local keys = require("reviewer.keys")

local M = { win = nil, buf = nil, kind = nil, hidden = false }
local ns = vim.api.nvim_create_namespace("reviewer_keybar")

-- { section, option name, label, in the bar }. A literal key instead of an
-- option name is a string in [ ]. Only the entries marked true are in the bar
-- (the most used ones, like lazygit), unless the key_bar option hides or adds
-- some; the help float lists them all.
local ENTRIES = {
  file = {
    { "file", { "next_change", "prev_change" }, "Change", true },
    { "file", { "next_file", "prev_file" }, "File", true },
    { "file", "toggle_read", "Read" }, { "file", "read_next", "Read + next", true },
    { "file", "show_comment", "Comment", true }, { "file", "note", "Note", true }, { "file", "ask", "Ask Claude", true },
    { "file", "browse", "Files", true },
    { "file", "explain", "Write comments" }, { "file", "comments_style", "Boxes / markers" },
    { "file", "about", "About the file" }, { "file", "toggle_split", "Side by side" },
    { "file", "help", "Keybindings", true },
  },
  browser = {
    { "browser", "open", "Open", true }, { "browser", "parent", "Up", true }, { "browser", "root", "Root" },
    { "[x] :w", nil, "Mark read", true }, { "browser", "toggle_view", "Reading order", true },
    { "browser", "explain", "Comment file" },
    { "browser", "prepare", "Prepare" }, { "browser", "overview", "Overview" },
    { "browser", "quiz", "Quiz", true }, { "browser", "progress", "Progress" }, { "browser", "notes", "Notes" },
    { "browser", "new_review", "Other branches" }, { "browser", "close", "Back to file" }, { "browser", "help", "Keybindings", true },
  },
  quiz = {
    { "quiz", "choices", "Pick", true }, { "quiz", "check", "Check / next", true }, { "quiz", "answer", "Answer", true },
    { "quiz", "dont_know", "Don't know" }, { "quiz", "next", "Next" }, { "quiz", "prev", "Previous" },
    { "quiz", "hint", "Hint", true }, { "quiz", "explain", "Ask why" }, { "quiz", "refs", "Open code" },
    { "quiz", "retry", "Retry" }, { "quiz", "overview", "Results" }, { "quiz", "close", "Close", true },
  },
}

local LONG = {
  file = {
    next_change = "next / previous change", next_file = "next / previous file of the review",
    toggle_read = "toggle the read mark",
    read_next = "mark read and open the next unread file", browse = "review browser on this folder",
    ask = "ask Claude about the file (visual: about the lines)", explain = "write Claude's comments on this file",
    comments_style = "Claude's comments as boxes / as markers (comment key to read one)",
    show_comment = "Claude's comment of the code under the cursor (again: go into it, q to leave)", about = "summary, changes and commits of the file",
    toggle_split = "inline changes / side by side", help = "this help",
    note = "your note on this line (visual: on the lines); on a note: edit it, empty deletes it",
  },
}

-- Option names of an entry: a pair has two, the literal "[x] :w" is "mark_read".
local function names_of(e)
  if type(e[2]) == "table" then return e[2] end
  return { e[2] or "mark_read" }
end

local function listed(kind, which, e)
  local list = ((config.options.key_bar or {})[which] or {})[kind] or {}
  for _, n in ipairs(names_of(e)) do
    if vim.tbl_contains(list, n) then return true end
  end
  return false
end

-- Is the entry in the bar: marked true or added by key_bar.show, and not hidden by key_bar.hide.
local function in_bar(kind, e)
  if listed(kind, "hide", e) then return false end
  return e[4] == true or listed(kind, "show", e)
end

local function label_of(section, name)
  if not name then return section end
  -- a pair of options (next / previous): their first keys, "↓/↑"
  if type(name) == "table" then
    local o = keys.opts(section)
    local a, b = keys.label(o[name[1]]), keys.label(o[name[2]])
    if a == "" or b == "" then return a .. b end
    return a .. "/" .. b
  end
  local v = keys.opts(section)[name]
  if section == "quiz" and name == "choices" then return (v and v ~= "") and (v:sub(1, 1) .. "-" .. v:sub(-1)) or "" end
  if section == "quiz" and name == "refs" then
    local l = keys.list(v)
    return #l > 1 and (l[1] .. "-" .. l[#l]) or (l[1] or "")
  end
  return (keys.labels(v):gsub(" ", "/"))
end

-- "<leader>rr" is long: show the leader itself ("␣rr" for a space), and arrows as ↓ ↑ → ←.
local ARROWS = { ["<down>"] = "↓", ["<up>"] = "↑", ["<right>"] = "→", ["<left>"] = "←" }
local function short(k)
  local leader = vim.g.mapleader or "\\"
  leader = leader == " " and "␣" or leader
  k = k:gsub("<[Ll]eader>", function() return leader end)
  return (k:gsub("<%a+>", function(m) return ARROWS[m:lower()] end))
end

-- Kind of review buffer shown in a window, or nil.
local function kind_of(buf)
  if require("reviewer.core").buffers[buf] then return "file" end
  if require("reviewer.browser").is_browser(buf) then return "browser" end
  if require("reviewer.quiz").buf == buf then return "quiz" end
end

-- One line, like lazygit's: "Label: key | Label: key". Entries that do not fit
-- are dropped from the end, but the help entry is kept (unless hidden).
local function chunks(kind, width)
  local items = {}
  for _, e in ipairs(ENTRIES[kind]) do
    if in_bar(kind, e) then
      local k = short(label_of(e[1], e[2]))
      if k ~= "" then items[#items + 1] = { label = e[3], key = k, help = e[2] == "help" } end
    end
  end
  local sep = " | "
  local function total(list)
    local w = 1
    for i, it in ipairs(list) do
      w = w + vim.fn.strdisplaywidth(it.label .. ": " .. it.key) + (i > 1 and #sep or 0)
    end
    return w
  end
  while #items > 1 and total(items) > width do
    local last = #items
    if items[last].help then last = last - 1 end
    table.remove(items, last)
  end
  local line, hls = " ", {}
  for i, it in ipairs(items) do
    if i > 1 then
      hls[#hls + 1] = { 0, #line, #line + #sep, "ReviewerKeySep" }
      line = line .. sep
    end
    local label = it.label .. ": "
    hls[#hls + 1] = { 0, #line, #line + #label, "ReviewerKeyDesc" }
    line = line .. label
    hls[#hls + 1] = { 0, #line, #line + #it.key, "ReviewerKey" }
    line = line .. it.key
  end
  return { line }, hls
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
    local k, name = label_of(e[1], e[2]), e[2]
    if type(name) == "table" then -- every key of both options
      local o = keys.opts(e[1])
      k = vim.trim(keys.labels(o[name[1]]) .. " / " .. keys.labels(o[name[2]]))
      name = name[1]
    end
    if k ~= "" and k ~= "/" then out[#out + 1] = ("%-16s %s"):format(k, (LONG[kind] and name and LONG[kind][name]) or e[3]) end
  end
  vim.list_extend(out, { "", "Commands: :Review <Tab> lists them (:Review quiz, :Review progress, :Review asks, ...).", ":Review keys shows or hides the key bar." })
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
