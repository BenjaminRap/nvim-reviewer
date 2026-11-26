local fx = require("tests.fixture")

describe("review", function()
  it("has one command, with subcommands and branch names to complete", function()
    fx.review()
    expect(vim.fn.exists(":Review")).equal(2)
    expect(vim.fn.exists(":ReviewQuiz")).equal(0, "no other command")
    local r = require("reviewer")
    local first = r.complete("", "Review ")
    expect(vim.tbl_contains(first, "quiz")).truthy("subcommand")
    expect(vim.tbl_contains(first, "feature")).truthy("branch")
    expect(r.complete("q", "Review q")).equal({ "quiz" })
    expect(r.complete("", "Review quiz ")).equal({ "list", "mistakes" })
    expect(vim.tbl_contains(r.complete("", "Review main "), "feature")).truthy("second branch")
    -- a subcommand runs; anything else is read as branches
    local called
    local orig = r.commands.split
    r.commands.split = function() called = true end
    vim.cmd("Review split")
    r.commands.split = orig
    expect(called).truthy("subcommand run")
  end)

  it("reads branch names on the remote", function()
    local step = fx.review()
    expect(step.id).equal("main..feature")
    expect(step.base_ref).equal("origin/main")
    expect(step.head_ref).equal("origin/feature")
  end)

  it("lists the changed files with their status", function()
    local by = {}
    for _, f in ipairs(require("reviewer.core").files()) do by[f.path] = f end
    expect(by["src/app.ts"].status).equal("M")
    expect({ by["src/app.ts"].add, by["src/app.ts"].del }).equal({ 3, 2 }, "app.ts +/-")
    expect(by["src/new.ts"].status).equal("A")
    expect(by["src/old.ts"].status).equal("D")
    expect(by["src/renamed.ts"].status).equal("R")
    expect(by["src/renamed.ts"].old).equal("src/name.ts")
    expect(by["package-lock.json"].generated).truthy("lockfile is generated")
  end)

  it("uses a hidden checkout when the branch is not checked out", function()
    local core, git = require("reviewer.core"), require("reviewer.git")
    local dir = git.step_dir(core.project, core.step, true)
    expect(dir).equal(core.project.worktree)
    expect(vim.uv.fs_stat(dir .. "/src/new.ts") ~= nil).truthy("file of the branch on disk")
  end)

  it("uses your own checkout when it is on the branch", function()
    fx.git({ "checkout", "-q", "--detach", "origin/feature" }, fx.root)
    local ok, err = pcall(function()
      require("reviewer.core").step = nil
      fx.review()
      local core, git = require("reviewer.core"), require("reviewer.git")
      expect(git.step_dir(core.project, core.step, true)).equal(core.project.root)
    end)
    fx.git({ "checkout", "-q", "main" }, fx.root)
    require("reviewer.core").step = nil
    fx.review()
    assert(ok, err)
  end)

  it("accepts an id instead of two names", function()
    local core = require("reviewer.core")
    expect(core.review(core.project, "main..feature").head_ref).equal("origin/feature")
  end)

  it("reports an unknown branch", function()
    local core = require("reviewer.core")
    local r, err = core.review(core.project, "main", "nope")
    expect(r).equal(nil)
    expect(err).contains("unknown branch")
  end)
end)
