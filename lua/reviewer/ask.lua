-- Ask Claude about a reviewed file or selected lines. Claude runs in the step's
-- folder with read-only tools, so it can open any file of the repo at that step.
-- Each question starts a conversation: the answer shows in a chat window where
-- you can reply. Replies resume the same Claude Code session; when it cannot
-- be resumed, the conversation so far is sent again.
-- Every conversation is saved and listed in :Review asks and :Review progress.
local config = require("reviewer.config")
local core = require("reviewer.core")
local state = require("reviewer.state")
local claude = require("reviewer.claude")
local diff = require("reviewer.diff")
local explain = require("reviewer.explain")
local keys = require("reviewer.keys")
local ui = require("reviewer.ui")

local M = {}

M.BRIEF_CHARS = 6000

local pending = {} -- conversation id -> the message Claude is answering
local chat = { buf = nil, win = nil, id = nil }

-- The turns of a conversation. A question saved before conversations existed
-- becomes a conversation of one turn.
function M.turns(a)
  if type(a.turns) ~= "table" then
    a.turns = { { question = a.question, answer = a.answer, error = a.error, at = a.at } }
    a.answer, a.error = nil, nil
  end
  return a.turns
end

-- The saved conversation of `entry`, which is saved first if it is new.
local function stored(entry)
  local asks = state.get(core.project).asks
  for _, a in ipairs(asks) do
    if a == entry or (entry.id and a.id == entry.id) then return a end
  end
  table.insert(asks, entry)
  return entry
end

local function find(id)
  for _, a in ipairs(state.get(core.project).asks) do
    if a.id == id then return a end
  end
end

local function chat_open()
  return chat.win and vim.api.nvim_win_is_valid(chat.win) and chat.buf and vim.api.nvim_buf_is_valid(chat.buf)
end

-- The conversation as Markdown, and the line where its last turn starts.
local function chat_lines(a)
  local lines, last = { "# " .. (a.title or "Question"), "" }, 1
  local function add(text) vim.list_extend(lines, vim.split(text, "\n")) end
  local function turn(question, at, answer)
    last = #lines + 1
    lines[#lines + 1] = "## You" .. (at and (" · " .. ui.fmt_date(at)) or "")
    lines[#lines + 1] = ""
    add(question or "")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Claude"
    lines[#lines + 1] = ""
    add(answer)
    lines[#lines + 1] = ""
  end
  for _, t in ipairs(M.turns(a)) do
    turn(t.question, t.at, t.answer or ("_" .. (t.error or "no answer") .. "_"))
  end
  if pending[a.id] then turn(pending[a.id], nil, "_Claude is answering" .. config.options.symbols.pending .. "_") end
  return lines, last
end

-- Show the conversation in the chat window, scrolled to its last turn.
local function show(a)
  if not a.id then
    a.id = state.uid("a")
    state.save(core.project)
  end
  local lines, last = chat_lines(a)
  if not (chat_open() and chat.id == a.id) then
    if chat_open() then pcall(vim.api.nvim_win_close, chat.win, true) end
    local close, reply = keys.opts("float").close, keys.opts("ask").reply
    local buf, win = ui.float({
      title = "Claude · " .. (a.title or ""), filetype = "markdown", width = math.min(110, vim.o.columns - 4),
      footer = ("%s reply · %s close"):format(keys.label(reply), keys.labels(close)),
    })
    chat.buf, chat.win, chat.id = buf, win, a.id
    local id = a.id
    keys.map(buf, "n", close, function() pcall(vim.api.nvim_win_close, win, true) end, "close")
    keys.map(buf, "n", reply, function() M.reply(id) end, "reply to Claude")
  end
  ui.set_lines(chat.buf, lines)
  pcall(vim.api.nvim_win_set_cursor, chat.win, { last, 0 })
  vim.api.nvim_win_call(chat.win, function() vim.cmd("normal! zt") end)
end
M.show_answer = show

-- The start of a context, kept to send the conversation again when its
-- session cannot be resumed.
local function brief_of(context)
  if #context <= M.BRIEF_CHARS then return context end
  return context:sub(1, M.BRIEF_CHARS) .. "\n(context shortened)"
end

-- The whole conversation and a new message as one prompt, for a new session.
function M.replay(a, message)
  local parts = {
    "You are continuing an earlier conversation with the developer. Its context was:",
    "",
    a.brief or claude.PROJECT_INTRO,
    "",
    "Read the files again when you need the code. The conversation so far:",
  }
  for _, t in ipairs(M.turns(a)) do
    parts[#parts + 1] = "\nDeveloper:\n" .. (t.question or "")
    parts[#parts + 1] = "\nYou:\n" .. (t.answer or ("(no answer: " .. (t.error or "unknown") .. ")"))
  end
  parts[#parts + 1] = "\nThe developer's new message:\n" .. message
  return table.concat(parts, "\n")
end

-- Send one message of the conversation `a`; the answer is saved and shown.
local function send(a, message, prompt)
  pending[a.id] = message
  show(a)
  local opts = { tools = config.options.claude.ask_tools, cwd = a.cwd, use = "ask", session = true, resume = a.session }
  local function done(err, text, meta)
    if err and opts.resume and err ~= "cancelled" then
      -- the session is gone or failed: a new one gets the whole conversation
      opts.resume = nil
      return claude.run(M.replay(a, message), opts, done)
    end
    pending[a.id] = nil
    local saved = stored(a)
    local turns = M.turns(saved)
    turns[#turns + 1] = { question = message, answer = text, error = err, at = state.now() }
    saved.at = turns[#turns].at
    if meta and meta.session_id then saved.session = meta.session_id end
    state.save(core.project)
    core.changed()
    show(saved)
  end
  claude.run(prompt, opts, done)
end

-- Start a conversation. entry: { kind, title, question, ... }; context: what
-- Claude needs to know; cwd: where Claude runs (replies run there too).
function M.run(entry, context, cwd)
  entry.id = entry.id or state.uid("a")
  entry.cwd, entry.turns = cwd, {}
  entry.brief = entry.brief or brief_of(context)
  send(entry, entry.question, context .. "\n\nThe developer's question:\n" .. entry.question)
end

-- Write a reply in the conversation with this id.
function M.reply(id)
  local a = find(id)
  if not a then return ui.notify("this conversation is not saved", vim.log.levels.WARN) end
  if pending[id] then return ui.notify("Claude is still answering") end
  ui.input({ title = "Reply · " .. (a.title or "") }, function(text)
    send(a, text, a.session and text or M.replay(a, text))
  end)
end

-- brief: without the listing of the whole file.
function M.file_context(ctx, l1, l2, brief)
  local p, s, f = ctx.project, ctx.step, ctx.file
  local e = explain.get(ctx)
  local parts = {
    claude.PROJECT_INTRO,
    "",
    ("Repository %s. The review covers branch %s compared with %s (%s..%s). Your working directory holds the code at the head of the reviewed branch; you may read other files to answer."):format(p.name, s.branch, s.base_branch, s.base_ref, s.head_ref),
    ("Current file: %s (%s, +%d −%d)."):format(f.path, explain.STATUS[f.status] or f.status, f.add, f.del),
  }
  if e then parts[#parts + 1] = "Earlier summary of this file: " .. e.summary .. " " .. e.changes end
  if not brief then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "The whole file with this step's changes (\"+\" added, \"-\" removed with old line number; numbers are new line numbers):"
    parts[#parts + 1] = "```"
    parts[#parts + 1] = diff.listing(ctx.lines, ctx.hunks, 120000)
    parts[#parts + 1] = "```"
  end
  if l1 then
    parts[#parts + 1] = ("The question is about lines %d-%d:"):format(l1, l2)
    parts[#parts + 1] = "```"
    parts[#parts + 1] = diff.numbered(ctx.lines, l1, l2)
    parts[#parts + 1] = "```"
  end
  return table.concat(parts, "\n")
end

function M.ask_here(l1, l2)
  local ctx = require("reviewer.review").current_ctx()
  if not ctx then return ui.notify("open a reviewed file first", vim.log.levels.WARN) end
  local sel = false
  local mode = vim.fn.mode()
  if l1 == nil and (mode == "v" or mode == "V" or mode == "\22") then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    l1, l2 = math.min(a, b), math.max(a, b)
    sel = true
  elseif l1 then sel = true end
  local title = ("%s%s"):format(ctx.file.path, sel and ((":%d"):format(l1) .. (l2 > l1 and ("-" .. l2) or "")) or "")
  ui.input({ title = "Ask Claude · " .. title }, function(q)
    local from = sel and l1 or nil
    M.run({ kind = "file", step = ctx.step.id, path = ctx.file.path, line = l1, end_line = l2, question = q, title = title,
      brief = brief_of(M.file_context(ctx, from, l2, true)) }, M.file_context(ctx, from, l2), ctx.dir)
  end)
end

function M.describe(a)
  local n = #M.turns(a)
  return ("%s · %s  %s%s"):format(ui.fmt_date(a.at), a.title or "", (a.question or ""):gsub("\n", " "):sub(1, 70),
    n > 1 and ("  (" .. n .. " messages)") or "")
end

function M.list()
  if not core.project then return ui.notify("run :Review first", vim.log.levels.WARN) end
  local asks = vim.list_slice(state.get(core.project).asks)
  if #asks == 0 then return ui.notify("no questions asked yet") end
  table.sort(asks, function(a, b) return (a.at or "") > (b.at or "") end)
  vim.ui.select(asks, { prompt = "Conversations with Claude", format_item = M.describe }, function(a)
    if a then vim.schedule(function() show(a) end) end
  end)
end

return M
