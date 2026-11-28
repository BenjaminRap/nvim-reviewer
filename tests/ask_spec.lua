local fx = require("tests.fixture")

-- The text of the conversation window, or nil when none is open.
local function chat_text()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "markdown" then
      return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n"), w
    end
  end
end

local function close_chat()
  local _, w = chat_text()
  if w then vim.api.nvim_win_close(w, true) end
end

-- Write `text` in the input that is open, then send it.
local function type_input(text)
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n"))
  fx.press("<CR>")
end

describe("ask", function()
  local claude, ask = require("reviewer.claude"), require("reviewer.ask")
  local real = claude.run
  local calls

  local function stub(reply)
    calls = {}
    claude.run = function(prompt, opts, cb)
      calls[#calls + 1] = { prompt = prompt, opts = vim.deepcopy(opts) }
      reply(#calls, prompt, opts, cb)
    end
  end

  it("opens a conversation and replies in the same Claude session", function()
    fx.review()
    require("reviewer.review").open_path(require("reviewer.core").step, "src/app.ts")
    fx.cursor_on("const b = 20")
    stub(function(n, _, _, cb)
      cb(nil, n == 1 and "Because of the test." or "Line 2 sets it.", { cost = 0, session_id = "s-1" })
    end)
    ask.ask_here()
    type_input("why 20?")
    local text = chat_text()
    expect(text).contains("why 20?")
    expect(text).contains("Because of the test.")
    expect(calls[1].opts.session).truthy("the session is kept")
    expect(calls[1].opts.resume == nil).truthy("a new session")
    fx.press("r")
    type_input("where exactly?")
    claude.run = real
    expect(#calls).equal(2)
    expect(calls[2].opts.resume).equal("s-1", "the reply resumes the session")
    expect(calls[2].prompt).equal("where exactly?", "only the new message is sent")
    text = chat_text()
    expect(text).contains("Because of the test.")
    expect(text).contains("where exactly?")
    expect(text).contains("Line 2 sets it.")
    close_chat()
    local saved = require("reviewer.state").get(require("reviewer.core").project).asks
    expect(#ask.turns(saved[#saved])).equal(2, "both turns saved")
  end)

  it("sends the whole conversation again when the session cannot be resumed", function()
    local core, state = require("reviewer.core"), require("reviewer.state")
    local a = state.get(core.project).asks[1]
    stub(function(n, _, _, cb)
      if n == 1 then return cb("No conversation found") end
      cb(nil, "Here it is again.", { cost = 0, session_id = "s-2" })
    end)
    ask.show_answer(a)
    fx.press("r")
    type_input("and then?")
    claude.run = real
    expect(#calls).equal(2)
    expect(calls[2].opts.resume == nil).truthy("a new session")
    expect(calls[2].prompt).contains("why 20?")
    expect(calls[2].prompt).contains("Line 2 sets it.")
    expect(calls[2].prompt).contains("and then?")
    expect(a.session).equal("s-2")
    expect(chat_text()).contains("Here it is again.")
    close_chat()
  end)

  it("continues a question saved before conversations existed", function()
    local core, state = require("reviewer.core"), require("reviewer.state")
    local old = { kind = "file", title = "src/app.ts", question = "old q", answer = "old a", at = state.now() }
    table.insert(state.get(core.project).asks, old)
    ask.show_answer(old)
    expect(chat_text()).contains("old a")
    stub(function(_, _, _, cb) cb(nil, "new a", { cost = 0, session_id = "s-3" }) end)
    fx.press("r")
    type_input("new q")
    claude.run = real
    expect(calls[1].opts.resume == nil).truthy("no session to resume")
    expect(calls[1].prompt).contains("old a")
    expect(#ask.turns(old)).equal(2)
    expect(ask.describe(old)).contains("(2 messages)")
    close_chat()
    vim.cmd("only")
  end)
end)

describe("claude sessions", function()
  it("keeps a session only when asked, and resumes one", function()
    local claude = require("reviewer.claude")
    local real_system = vim.system
    local cmds = {}
    vim.system = function(cmd, _, on_exit)
      cmds[#cmds + 1] = table.concat(cmd, " ")
      on_exit({ code = 1, stdout = "", stderr = "stub" })
      return { kill = function() end }
    end
    claude.run("x", {}, function() end)
    claude.run("x", { session = true }, function() end)
    claude.run("x", { session = true, resume = "abc" }, function() end)
    vim.wait(100, function() return claude.busy() == 0 end)
    vim.system = real_system
    expect(cmds[1]).contains("--no-session-persistence")
    expect(cmds[2]:find("--no-session-persistence", 1, true) == nil).truthy("kept")
    expect(cmds[3]).contains("--resume abc")
  end)
end)
