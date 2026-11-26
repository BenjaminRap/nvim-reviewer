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
    expect(qf[1].text).equal("check c")
    vim.cmd("cclose")
  end)
end)
