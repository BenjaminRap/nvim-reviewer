-- Draws a reviewed file: added lines highlighted, removed lines shown in place,
-- Claude's comments and your notes, all with extmarks (the file is not changed).
local config = require("reviewer.config")
local state = require("reviewer.state")
local ui = require("reviewer.ui")

local M = {}
M.ns = vim.api.nvim_create_namespace("reviewer")

function M.setup_highlights()
  local links = {
    ReviewerAdd = "DiffAdd", ReviewerAddSign = "Added",
    ReviewerDelete = "DiffDelete", ReviewerDeleteSign = "Removed",
    ReviewerComment = "DiagnosticVirtualTextInfo", ReviewerCommentTitle = "DiagnosticInfo",
    ReviewerNote = "DiagnosticVirtualTextWarn", ReviewerQuestion = "DiagnosticVirtualTextHint", ReviewerIssue = "DiagnosticVirtualTextError",
    ReviewerRead = "Comment", ReviewerGroup = "Title", ReviewerHeader = "Title", ReviewerDim = "Comment",
    ReviewerOk = "DiagnosticOk", ReviewerBad = "DiagnosticError", ReviewerPartial = "DiagnosticWarn",
    ReviewerCurrent = "CursorLine", ReviewerFlash = "IncSearch", ReviewerAction = "Function",
  }
  for k, v in pairs(links) do vim.api.nvim_set_hl(0, k, { link = v, default = true }) end
end

local function sym(name) return config.options.symbols[name] end
local KIND = setmetatable({
  note = { sym = "note", hl = "ReviewerNote", name = "Note" },
  question = { sym = "question", hl = "ReviewerQuestion", name = "Question" },
  issue = { sym = "issue", hl = "ReviewerIssue", name = "Issue" },
  ai = { sym = "answer", hl = "ReviewerComment", name = "Claude answer" },
}, {})
for _, k in pairs(KIND) do setmetatable(k, { __index = function(t, key) if key == "sign" then return sym(t.sym) end end }) end
M.KIND = KIND

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

function M.notes_for(ctx)
  local list = {}
  for _, n in ipairs(state.get(ctx.project).notes) do
    if n.step == ctx.step.id and n.path == ctx.file.path then list[#list + 1] = n end
  end
  return list
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
  if config.options.show_comments then
    local e = require("reviewer.explain").get(ctx)
    if e and e.comments then
      local by_hunk = {}
      for _, h in ipairs(ctx.hunks) do by_hunk[h.id] = h end
      local at = {}
      for _, c in ipairs(e.comments) do
        local h = by_hunk[c.block]
        local line = (c.line and c.line >= 1 and c.line <= nlines) and c.line or (h and h.anchor) or nil
        if line then
          local above = not (h and not h.above and not c.line)
          local key = line .. (above and "a" or "b")
          at[key] = at[key] or { line = line, above = above, texts = {} }
          table.insert(at[key].texts, c.text)
        end
      end
      for _, a in pairs(at) do
        local vl = comment_lines(a.texts, math.min(width, (config.options.comment_width or 100) + 6))
        if a.line == 1 and a.above then top_fill = top_fill + #vl end
        vim.api.nvim_buf_set_extmark(buf, M.ns, row(a.line), 0, { virt_lines = vl, virt_lines_above = a.above, priority = 20 })
      end
    end
  end

  if ctx.deleted then
    for l = 1, nlines do
      vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = "ReviewerDelete", sign_text = sym("removed"), sign_hl_group = "ReviewerDeleteSign" })
    end
  else
    for _, h in ipairs(ctx.hunks) do
      if h.new_count > 0 then
        for l = h.new_start, math.min(nlines, h.new_start + h.new_count - 1) do
          vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = "ReviewerAdd", sign_text = sym("added"), sign_hl_group = "ReviewerAddSign", priority = 10 })
        end
      end
      if #h.removed > 0 and config.options.show_removed then
        local vl = {}
        for _, r in ipairs(h.removed) do
          local t = r:gsub("\t", string.rep(" ", ts))
          vl[#vl + 1] = { { pad(sym("removed_prefix") .. t, width), "ReviewerDelete" } }
        end
        if h.anchor == 1 and h.above then top_fill = top_fill + #vl end
        vim.api.nvim_buf_set_extmark(buf, M.ns, row(h.anchor), 0, { virt_lines = vl, virt_lines_above = h.above, priority = 10 })
      end
    end
  end

  for _, n in ipairs(M.notes_for(ctx)) do
    local k = KIND[n.kind] or KIND.note
    local first = (n.text or ""):gsub("\n.*", "")
    vim.api.nvim_buf_set_extmark(buf, M.ns, row(n.line), 0, {
      sign_text = k.sign, sign_hl_group = k.hl, priority = 30,
      virt_text = { { "  " .. k.sign .. " " .. (n.done and "(resolved) " or "") .. first:sub(1, 90), n.done and "ReviewerDim" or k.hl } },
      virt_text_pos = "eol",
    })
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

function M.draw_all()
  local core = require("reviewer.core")
  for buf in pairs(core.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then M.draw(buf) else core.buffers[buf] = nil end
  end
end

return M
