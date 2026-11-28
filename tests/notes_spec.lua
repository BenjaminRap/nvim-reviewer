local fx = require("tests.fixture")

local function note_marks()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, require("reviewer.render").ns, 0, -1, { details = true })) do
    -- the note itself: a virtual line above its line, its text after the ✎
    for _, l in ipairs(m[4].virt_lines or {}) do
      for i, c in ipairs(l) do
        if c[2] == "ReviewerNote" and l[i + 1] then
          out[#out + 1] = { line = m[2] + 1, text = l[i + 1][1] }
          break
        end
      end
    end
  end
  return out
end

-- Write `text` in the note input that edit_here opened, then save it.
local function type_note(text)
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n"))
  fx.press("<CR>")
end

describe("notes", function()
  it("adds a note on a line and shows it there", function()
    fx.review()
    require("reviewer.review").open_path(require("reviewer.core").step, "src/app.ts")
    fx.cursor_on("const b = 20")
    require("reviewer.notes").edit_here()
    type_note("why 20?")
    local m = note_marks()
    expect(#m).equal(1, "one note")
    expect(m[1].line).equal(2)
    expect(m[1].text).equal("why 20?")
  end)

  it("edits the note under the cursor, and an empty note deletes it", function()
    fx.cursor_on("const b = 20")
    require("reviewer.notes").edit_here()
    expect(vim.api.nvim_get_current_line()).equal("why 20?", "the input holds the note")
    type_note("why 20 and not 2?")
    expect(note_marks()[1].text).equal("why 20 and not 2?")
    fx.cursor_on("const b = 20")
    require("reviewer.notes").edit_here()
    type_note("")
    expect(#note_marks()).equal(0, "deleted")
  end)

  it("stays on the line it was written on inside a changed block", function()
    fx.cursor_on("export { a, b, c, d }") -- second line of the block "const d = 4" / "export ..."
    require("reviewer.notes").edit_here()
    type_note("about d")
    local m = note_marks()
    expect(#m).equal(1, "one note")
    expect(m[1].line).equal(5, "on its own line, not the top of the block")
    expect(m[1].text).equal("about d")
    fx.cursor_on("const d = 4")
    require("reviewer.notes").edit_here()
    expect(vim.api.nvim_get_current_line()).equal("", "another line of the block starts a new note")
    vim.cmd("stopinsert")
    fx.press("q")
    fx.cursor_on("export { a, b, c, d }")
    require("reviewer.notes").edit_here()
    expect(vim.api.nvim_get_current_line()).equal("about d", "the note is edited from its own line")
    type_note("")
    expect(#note_marks()).equal(0, "deleted")
  end)

  it("keeps the lines of a note saved on a whole block", function()
    local notes = require("reviewer.notes")
    expect({ notes.resolve({ line = 4, end_line = 5, code = "const d = 4" }, { "x", "y", "z", "const d = 4", "e" }) }).equal({ 4, 5 })
  end)

  it("follows its line when the code moves, and lists notes in the quickfix list", function()
    local notes = require("reviewer.notes")
    expect(notes.resolve({ line = 2, code = "b" }, { "x", "a", "b" })).equal(3)
    expect(notes.resolve({ line = 9, code = "gone" }, { "a", "b" })).equal(2)
    fx.cursor_on("const c = 3")
    notes.edit_here()
    type_note("check c")
    expect(notes.count("src/app.ts")).equal(1)
    notes.quickfix()
    local qf = vim.fn.getqflist()
    expect(#qf).equal(1)
    expect(qf[1].lnum).equal(3)
    expect(qf[1].text).equal("[note] check c")
    vim.cmd("cclose")
  end)

  it("makes questions and issues from ? and !, and marks them done", function()
    local notes = require("reviewer.notes")
    expect({ notes.parse("? why") }).equal({ "question", "why" })
    expect({ notes.parse("! bug") }).equal({ "issue", "bug" })
    expect({ notes.parse("!bang") }).equal({ "note", "!bang" }, "a space is needed after the mark")
    fx.cursor_on("const a = 1")
    notes.edit_here()
    type_note("? why 1?")
    fx.cursor_on("const d = 4")
    notes.edit_here()
    type_note("! d is never used")
    local all = notes.of_file("src/app.ts")
    local kinds = {}
    for _, n in ipairs(all) do kinds[n.text] = n.kind end
    expect(kinds["why 1?"]).equal("question")
    expect(kinds["d is never used"]).equal("issue")
    notes.quickfix("open")
    expect(#vim.fn.getqflist()).equal(2, "the question and the issue, not the plain note")
    vim.cmd("cclose")
    fx.cursor_on("const d = 4")
    notes.toggle_done_here()
    notes.quickfix("open")
    expect(#vim.fn.getqflist()).equal(1, "the issue is done")
    expect(vim.fn.getqflist()[1].text).contains("[question] why 1?")
    vim.cmd("cclose")
  end)

  it("answers open questions in one call and shows the answer with the comment key", function()
    local notes, claude, render = require("reviewer.notes"), require("reviewer.claude"), require("reviewer.render")
    local real_run, real_select = claude.run, vim.ui.select
    local prompt
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    claude.run = function(p, _, cb)
      prompt = p
      local id
      for _, n in ipairs(notes.of_file("src/app.ts")) do if n.kind == "question" then id = n.id end end
      cb(nil, { answers = { { id = id, answer = "Because the test expects 1." } } })
    end
    notes.answer()
    vim.wait(200, function() return prompt ~= nil end)
    claude.run, vim.ui.select = real_run, real_select
    expect(prompt).contains("why 1?")
    expect(prompt).contains("const a = 1", "the code around the question")
    fx.cursor_on("const a = 1")
    expect(render.hover(vim.api.nvim_get_current_buf())).truthy("float opened")
    local found
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        found = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
      end
    end
    render.close_hover()
    expect(found).contains("Because the test expects 1.")
  end)

  it("exports issues and open questions as Markdown", function()
    local text = require("reviewer.notes").export()
    vim.cmd("tabclose")
    expect(text).contains("## Issues")
    expect(text).contains("- [x] `src/app.ts:4`: d is never used")
    expect(text).contains("## Questions")
    expect(text).contains("`src/app.ts:1`: why 1?")
    expect(text:find("check c", 1, true) == nil).truthy("plain notes are left out")
  end)
end)
