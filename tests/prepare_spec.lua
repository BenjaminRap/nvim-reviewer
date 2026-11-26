local fx = require("tests.fixture")

describe("warning before preparing", function()
  local claude, prepare = require("reviewer.claude"), require("reviewer.prepare")

  -- Run prepare.step with vim.ui.select answering `answer`; returns the prompt and the Claude calls.
  local function run(opts, answer)
    local core = require("reviewer.core")
    local real_select, real_run = vim.ui.select, claude.run
    local prompt, calls = nil, {}
    vim.ui.select = function(items, o, cb) prompt = o.prompt; cb(answer and items[1] or items[2]) end
    claude.run = function(_, o) calls[#calls + 1] = o.use end
    prepare.step(core.step, opts)
    vim.wait(200, function() return #calls > 0 end)
    vim.ui.select, claude.run = real_select, real_run
    for _, j in pairs(prepare.jobs) do j.finished = true end
    return prompt, calls
  end

  it("shows what will run, and runs nothing on No", function()
    fx.review()
    local prompt, calls = run({ stages = { comments = true }, force = true }, false)
    expect(prompt).contains("comments on 4 files in 1 call")
    expect(prompt).contains("characters of code")
    expect(prompt).contains("overview (1 call)", "comments need the overview first")
    expect(#calls).equal(0, "nothing run")
  end)

  it("estimates the cost from past calls", function()
    local core = require("reviewer.core")
    local lines = {
      vim.json.encode({ use = "overview", cost = 2.0 }),
      vim.json.encode({ use = "overview", cost = 1.0 }),
      vim.json.encode({ use = "comments", cost = 1.0, prompt_chars = 100000 }),
    }
    vim.fn.writefile(lines, core.project.data_dir .. "/usage.jsonl")
    local plan = { overview = true, quiz = false, files = 3, calls = 1, chars = 50000 }
    expect(prepare.estimate(plan)).equal(1.5 + 0.5, "average overview + comments at the cost per character")
    expect(prepare.plan_text(plan)).contains("about $2.00 from your past calls")
    os.remove(core.project.data_dir .. "/usage.jsonl")
    expect(prepare.plan_text(plan)).contains("no past calls to estimate the cost from")
  end)

  it("runs once confirmed", function()
    local _, calls = run({ stages = { comments = true }, force = true }, true)
    expect(calls[1]).equal("overview", "started")
  end)
end)
