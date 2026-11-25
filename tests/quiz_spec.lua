local fx = require("tests.fixture")

describe("quiz", function()
  it("keeps only questions whose references and snippets match the code", function()
    fx.review()
    local kept, dropped = require("reviewer.prepare").validate({
      { type = "single", prompt = "ok", choices = { "a", "b" }, answer = { 1 }, code = "const b = 20", refs = { { path = "src/app.ts", line = 2 } } },
      { type = "single", prompt = "bad line", choices = { "a", "b" }, answer = { 0 }, refs = { { path = "src/app.ts", line = 99 } } },
      { type = "open", prompt = "bad code", code = "const z = 9", refs = { { path = "src/app.ts", line = 1 } } },
      { type = "single", prompt = "bad answer", choices = { "a" }, answer = { 3 }, refs = { { path = "src/app.ts", line = 1 } } },
    }, "origin/feature", "t-q")
    expect(#kept).equal(1, "kept")
    expect(#dropped).equal(3, "dropped")
    expect(kept[1].id).equal("t-q01")
  end)

  it("grades choice questions and saves the attempts", function()
    local core, quiz, state = require("reviewer.core"), require("reviewer.quiz"), require("reviewer.state")
    local id = core.step.id
    vim.fn.mkdir(core.project.quiz_dir, "p")
    vim.fn.writefile({ vim.json.encode({ id = id, title = "t", ref = "origin/feature", questions = {
      { id = "x-q1", level = 1, type = "single", prompt = "one", choices = { "a", "b", "c" }, answer = { 1 }, refs = {} },
      { id = "x-q2", level = 1, type = "multi", prompt = "two", choices = { "a", "b", "c" }, answer = { 0, 2 }, refs = {} },
    } }) }, core.quiz_file(id))
    quiz.reload()
    quiz.open_question(id, "x-q1")
    quiz.toggle_choice(2)
    quiz.submit()
    expect(state.get(core.project).attempts["x-q1"].last.verdict).equal("correct")
    quiz.go(1)
    quiz.toggle_choice(1)
    quiz.submit()
    expect(state.get(core.project).attempts["x-q2"].last.verdict).equal("partial")
    quiz.close()
  end)
end)
