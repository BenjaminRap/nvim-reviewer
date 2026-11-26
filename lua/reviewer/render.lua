-- Draws a reviewed file: added lines highlighted, removed lines shown in place,
-- and Claude's comments, all with extmarks (the file is not changed).
local config = require("reviewer.config")
local state = require("reviewer.state")
local ui = require("reviewer.ui")

local M = {}
M.ns = vim.api.nvim_create_namespace("reviewer")

local function sym(name) return config.options.symbols[name] end

function M.setup_highlights()
  local links = {
    ReviewerAdd = "DiffAdd", ReviewerAddSign = "Added",
    ReviewerDelete = "DiffDelete", ReviewerDeleteSign = "Removed",
    ReviewerComment = "DiagnosticVirtualTextInfo", ReviewerCommentTitle = "DiagnosticInfo",
    ReviewerRead = "Comment", ReviewerGroup = "Title", ReviewerHeader = "Title", ReviewerDim = "Comment",
    ReviewerOk = "DiagnosticOk", ReviewerBad = "DiagnosticError", ReviewerPartial = "DiagnosticWarn",
    ReviewerKey = "Special", ReviewerKeyDesc = "Comment", ReviewerKeyBar = "NormalFloat",
    ReviewerCurrent = "CursorLine", ReviewerFlash = "IncSearch", ReviewerAction = "Function",
  }
  for k, v in pairs(links) do vim.api.nvim_set_hl(0, k, { link = v, default = true }) end

  -- Changed characters inside a changed line: the line colour, a little stronger.
  local function get(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local function blend(bg, fg, alpha)
    if not bg or not fg then return nil end
    local function ch(c, s) return math.floor(bit.band(bit.rshift(c, s), 0xff)) end
    local out = 0
    for _, s in ipairs({ 16, 8, 0 }) do
      out = out + bit.lshift(math.floor(ch(bg, s) * (1 - alpha) + ch(fg, s) * alpha + 0.5), s)
    end
    return out
  end
  local function stronger(name, line, accent)
    local l, a = get(line), get(accent)
    local bg = blend(l.bg, a.fg, 0.3)
    if bg then vim.api.nvim_set_hl(0, name, { bg = bg, default = true })
    else vim.api.nvim_set_hl(0, name, { link = "DiffText", default = true }) end
  end
  stronger("ReviewerAddText", "DiffAdd", "Added")
  stronger("ReviewerDeleteText", "DiffDelete", "Removed")

  -- GitHub's colours, set explicitly (still overridable after setup).
  if config.options.colors == "github" then
    local dark = vim.o.background == "dark"
    local gh = dark and {
      ReviewerAdd = "#12261e", ReviewerAddText = "#1d572d", ReviewerAddSign = "#3fb950",
      ReviewerDelete = "#25171c", ReviewerDeleteText = "#6b2b2b", ReviewerDeleteSign = "#f85149",
    } or {
      ReviewerAdd = "#dafbe1", ReviewerAddText = "#abf2bc", ReviewerAddSign = "#1a7f37",
      ReviewerDelete = "#ffebe9", ReviewerDeleteText = "#ffcecb", ReviewerDeleteSign = "#cf222e",
    }
    for k, c in pairs(gh) do
      if k:find("Sign$") then vim.api.nvim_set_hl(0, k, { fg = c })
      else vim.api.nvim_set_hl(0, k, { bg = c }) end
    end
  end
end

-- Virtual-line chunks for a removed line, with its changed ranges stronger.
local function removed_chunks(text, ranges, width, ts)
  local function expand(s) return (s:gsub("\t", string.rep(" ", ts))) end
  local chunks = { { sym("removed_prefix"), "ReviewerDelete" } }
  local col, used = 0, vim.fn.strdisplaywidth(sym("removed_prefix"))
  local function add(s, hl)
    if s == "" then return end
    s = expand(s)
    chunks[#chunks + 1] = { s, hl }
    used = used + vim.fn.strdisplaywidth(s)
  end
  for _, r in ipairs(ranges or {}) do
    add(text:sub(col + 1, r[1]), "ReviewerDelete")
    add(text:sub(r[1] + 1, r[2]), "ReviewerDeleteText")
    col = r[2]
  end
  add(text:sub(col + 1), "ReviewerDelete")
  if used < width then chunks[#chunks + 1] = { string.rep(" ", width - used), "ReviewerDelete" } end
  return chunks
end

local function pad(text, width)
  local w = vim.fn.strdisplaywidth(text)
  return w < width and (text .. string.rep(" ", width - w)) or text
end

local function win_width(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do return vim.api.nvim_win_get_width(w) end
  return vim.o.columns
end

-- Comment boxes as virtual lines, wrapped to the window.
local function comment_lines(texts, width)
  local out = {}
  for i, t in ipairs(texts) do
    if i > 1 then out[#out + 1] = { { "", "" } } end
    local wrapped = ui.wrap(t, math.max(30, width - 6))
    local mark = " " .. sym("comment") .. " "
    local blank = string.rep(" ", vim.fn.strdisplaywidth(mark))
    for j, l in ipairs(wrapped) do
      out[#out + 1] = {
        { j == 1 and mark or blank, "ReviewerCommentTitle" },
        { pad(l, width - 4), "ReviewerComment" },
      }
    end
  end
  return out
end

function M.draw(buf)
  local core = require("reviewer.core")
  local ctx = core.buffers[buf]
  if not ctx or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local nlines = vim.api.nvim_buf_line_count(buf)
  local width = math.min(win_width(buf), 200)
  local ts = vim.bo[buf].tabstop
  local function row(l) return math.max(0, math.min(nlines - 1, (l or 1) - 1)) end
  local top_fill = 0

  -- Claude's comments first, so they sit above the removed lines of the same block.
  ctx.comment_at, ctx.comment_spots = nil, nil
  if config.options.show_comments then
    local e = require("reviewer.explain").get(ctx)
    if e and e.comments then
      local by_hunk = {}
      for _, h in ipairs(ctx.hunks) do by_hunk[h.id] = h end
      local at = {}
      for _, c in ipairs(e.comments) do
        local h = by_hunk[c.block]
        local pinned = c.line and c.line >= 1 and c.line <= nlines
        local line = pinned and c.line or (h and h.anchor) or nil
        if line then
          local above = not (h and not h.above and not c.line)
          local key = line .. (above and "a" or "b")
          -- the lines the comment is about: its own line, or every added line of its block
          local first, last = line, line
          if not pinned and h and h.new_count > 0 then
            first, last = h.new_start, math.min(nlines, h.new_start + h.new_count - 1)
          end
          at[key] = at[key] or { line = line, above = above, texts = {}, first = first, last = last }
          at[key].first, at[key].last = math.min(at[key].first, first), math.max(at[key].last, last)
          table.insert(at[key].texts, c.text)
        end
      end
      ctx.comment_at, ctx.comment_spots = {}, {}
      local spot_at = {}
      for _, a in pairs(at) do
        local sp = spot_at[a.line]
        if not sp then
          sp = { line = a.line, first = a.first, last = a.last, texts = {} }
          spot_at[a.line] = sp
          table.insert(ctx.comment_spots, sp)
        end
        sp.first, sp.last = math.min(sp.first, a.first), math.max(sp.last, a.last)
        vim.list_extend(sp.texts, a.texts)
        if config.options.comments == "hover" then
          -- a marker at the end of the line; the comment opens when the cursor is in its lines
          local texts = ctx.comment_at[a.line] or {}
          vim.list_extend(texts, a.texts)
          ctx.comment_at[a.line] = texts
        else
          local vl = comment_lines(a.texts, math.min(width, (config.options.comment_width or 100) + 6))
          if a.line == 1 and a.above then top_fill = top_fill + #vl end
          vim.api.nvim_buf_set_extmark(buf, M.ns, row(a.line), 0, { virt_lines = vl, virt_lines_above = a.above, priority = 20 })
        end
      end
      for line, texts in pairs(ctx.comment_at) do
        local first = (texts[1] or ""):gsub("%s+", " ")
        if vim.fn.strchars(first) > 60 then first = vim.fn.strcharpart(first, 0, 59) .. "…" end
        local more = #texts > 1 and (" (+" .. (#texts - 1) .. ")") or ""
        vim.api.nvim_buf_set_extmark(buf, M.ns, row(line), 0, {
          virt_text = { { "  " .. sym("comment") .. " ", "ReviewerCommentTitle" }, { first .. more, "ReviewerDim" } },
          virt_text_pos = "eol", priority = 20,
        })
      end
    end
  end

  local split = require("reviewer.split").active()
  if split and not ctx.deleted then
    -- side by side: Neovim's diff mode shows the changes
  elseif ctx.deleted then
    for l = 1, nlines do
      vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = "ReviewerDelete", sign_text = sym("removed"), sign_hl_group = "ReviewerDeleteSign" })
    end
  else
    for _, h in ipairs(ctx.hunks) do
      if h.new_count > 0 then
        for l = h.new_start, math.min(nlines, h.new_start + h.new_count - 1) do
          vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = "ReviewerAdd", sign_text = sym("added"), sign_hl_group = "ReviewerAddSign", priority = 10 })
        end
        if config.options.inline_changes then
          require("reviewer.diff").add_inline(h)
          for i, ranges in pairs(h.inline_added) do
            local l = h.new_start + i - 1
            local len = l <= nlines and #(vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or "") or 0
            for _, r in ipairs(ranges) do
              if r[1] < len then
                vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, r[1], { end_col = math.min(r[2], len), hl_group = "ReviewerAddText", priority = 11 })
              end
            end
          end
        end
      end
      if #h.removed > 0 and config.options.show_removed then
        local vl = {}
        local inline = config.options.inline_changes and require("reviewer.diff").add_inline(h)
        for i, r in ipairs(h.removed) do
          vl[#vl + 1] = removed_chunks(r, inline and h.inline_removed[i], width, ts)
        end
        if h.anchor == 1 and h.above then top_fill = top_fill + #vl end
        vim.api.nvim_buf_set_extmark(buf, M.ns, row(h.anchor), 0, { virt_lines = vl, virt_lines_above = h.above, priority = 10 })
      end
    end
  end

  -- Hint on the first line when Claude has not commented this file yet.
  if not ctx.file.generated and not ctx.file.binary then
    local ex = require("reviewer.explain")
    local hint
    if ex.status[ex.key(ctx)] == "pending" then hint = sym("comment") .. " Claude is writing comments on this file" .. sym("pending")
    elseif not ex.get(ctx) then
      local key = require("reviewer.keys").label(config.options.keymaps.file.explain)
      hint = sym("comment") .. " no Claude comments yet" .. ((key and key ~= "") and (": " .. key) or ": :ReviewExplain")
    end
    if hint then
      vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, { virt_text = { { "  " .. hint, "ReviewerDim" } }, virt_text_pos = "eol", priority = 5 })
    end
  end

  -- Virtual lines above line 1 are only visible when the window is scrolled to show them.
  if top_fill > 0 then
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(w, function()
        local v = vim.fn.winsaveview()
        if v.topline == 1 then vim.fn.winrestview({ topline = 1, topfill = top_fill }) end
      end)
    end
  end
end

-- Claude's comment of the code under the cursor, in a float (comments = "hover",
-- or on demand with the show_comment key). It stays open while the cursor is
-- anywhere in the commented block.
local hover = { win = nil, key = nil, entering = false }

-- The comment about this line: the narrowest one whose lines contain it.
function M.comment_spot(ctx, line)
  local best
  for _, sp in ipairs(ctx and ctx.comment_spots or {}) do
    if line >= sp.first and line <= sp.last
      and (not best or sp.last - sp.first < best.last - best.first) then best = sp end
  end
  return best
end

-- auto: called by the review buffer's autocmds, which must not close the
-- float while the cursor goes into it.
function M.close_hover(auto)
  if auto and hover.entering then return end
  if hover.win and vim.api.nvim_win_is_valid(hover.win) then pcall(vim.api.nvim_win_close, hover.win, true) end
  hover.win, hover.key = nil, nil
end

-- Below the block when its last line is on screen and there is room,
-- otherwise below (or above) the cursor line.
local function placement(buf, win, sp, line, n)
  local top = vim.fn.win_screenpos(win)[1]
  local bottom = top + vim.api.nvim_win_get_height(win) - 1
  local s = vim.fn.screenpos(win, sp.last, 1).row
  if s > 0 then
    local text = vim.api.nvim_buf_get_lines(buf, sp.last - 1, sp.last, false)[1] or ""
    local e = vim.fn.screenpos(win, sp.last, math.max(1, #text)).row
    local rows = (e >= s) and (e - s + 1) or 1
    local room = bottom - (s + rows - 1) - 2
    if room >= math.min(n, 3) then
      return { bufpos = { sp.last - 1, 0 }, row = rows, anchor = "NW", height = math.min(n, room, 20) }, false
    end
  end
  local below = vim.fn.winheight(win) - vim.fn.winline() - 2
  local height = math.min(n, math.max(below, vim.fn.winline() - 3), 20)
  local up = height > below
  return { bufpos = { line - 1, 0 }, row = up and 0 or 1, anchor = up and "SW" or "NW", height = height }, true
end

-- force: open it even in "inline" mode. Returns true when a float is shown.
function M.hover(buf, force)
  local ctx = require("reviewer.core").buffers[buf]
  local win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local sp = config.options.show_comments and (force or config.options.comments == "hover")
    and M.comment_spot(ctx, line) or nil
  local key = sp and (buf .. ":" .. win .. ":" .. sp.line)
  -- a float placed by the cursor follows it; one below the block stays put
  if key and hover.key and hover.key:find(key, 1, true) == 1 and hover.win and vim.api.nvim_win_is_valid(hover.win)
    and (hover.key == key or hover.key == key .. ":" .. line) then return true end
  M.close_hover()
  if not sp or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then return false end
  local width = math.max(30, math.min(config.options.comment_width or 100, vim.api.nvim_win_get_width(win) - 4))
  local lines = {}
  for i, t in ipairs(sp.texts) do
    if i > 1 then lines[#lines + 1] = "" end
    vim.list_extend(lines, ui.wrap(t, width - 2))
  end
  local fb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fb, 0, -1, false, lines)
  vim.bo[fb].filetype = "markdown"
  vim.bo[fb].bufhidden = "wipe"
  vim.bo[fb].modifiable = false
  local pos, follows = placement(buf, win, sp, line, #lines)
  local ok, w = pcall(vim.api.nvim_open_win, fb, false, {
    relative = "win", win = win, bufpos = pos.bufpos, row = pos.row, col = 0,
    anchor = pos.anchor, width = width, height = math.max(1, pos.height),
    style = "minimal", border = config.options.float.border or "rounded", focusable = true, zindex = 45,
    title = " " .. sym("comment") .. " Claude ", title_pos = "left", noautocmd = true,
  })
  if not ok then return false end
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].conceallevel = 2
  vim.wo[w].winhighlight = "NormalFloat:ReviewerComment,FloatBorder:ReviewerCommentTitle,FloatTitle:ReviewerCommentTitle"
  hover.win, hover.key = w, follows and (key .. ":" .. line) or key
  return true
end

-- The show_comment key: shows the comment of the code under the cursor; when
-- it is already shown, moves the cursor into it (to scroll or copy). q or
-- <Esc> there goes back.
function M.show_comment(buf)
  if not (hover.win and vim.api.nvim_win_is_valid(hover.win)) then
    if not config.options.show_comments then return ui.notify("Claude's comments are hidden", vim.log.levels.WARN) end
    if not M.hover(buf, true) then ui.notify("no comment from Claude on this line") end
    return
  end
  local from, w = vim.api.nvim_get_current_win(), hover.win
  local fb = vim.api.nvim_win_get_buf(w)
  local function back()
    if vim.api.nvim_win_is_valid(from) then vim.api.nvim_set_current_win(from) end
    M.close_hover()
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, back, { buffer = fb, nowait = true, desc = "close Claude's comment" })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = fb, once = true, callback = function()
    vim.schedule(function() if hover.win == w then M.close_hover() end end)
  end })
  hover.entering = true
  pcall(vim.api.nvim_set_current_win, w)
  hover.entering = false
end

function M.draw_all()
  local core = require("reviewer.core")
  for buf in pairs(core.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then M.draw(buf) else core.buffers[buf] = nil end
  end
end

return M
