# nvim-reviewer

Review a stack of branches in Neovim, one step at a time, file by file, in your real editor (LSP, search and your usual mappings all work).

When branches are built on top of each other (`main → feature-a → feature-b → feature-c`), each step is reviewed against the step before it, so you only see that step's own changes.

- **A whole step prepared in advance.** `:ReviewPrepare` has Claude read the step as a whole (overview, main flows, role of each file), comment every file in batches with that overview as context, and write a quiz on the step that is checked locally.
- **Full file with its changes.** Each file opens as a normal buffer, read-only by default. Added lines are highlighted and removed lines are shown in place, in red. The file itself is never modified.
- **Claude's comments.** The first time you open a file, Claude Code writes a summary and a comment above each change block. Comments are saved, so each file is commented once.
- **Read marks.** You can mark files, groups or whole folders as read in a side panel, with a reading order (database → shared → backend → frontend → tests) or a folder tree.
- **Notes on lines**, of three kinds: note, question to come back to, issue to fix. They appear in the sign column and at the end of the line.
- **Questions to Claude** about a file or selected lines. Claude runs in that step's checkout with read-only tools, so it can open any file of the repo. Questions and answers are saved.
- **Quizzes** per step and for the whole stack, from the big picture down to single lines. Choice questions are graded locally; Claude grades open answers against a reference answer. Mistakes are saved and can be retried.
- **Progress view.** Shows files read, quiz results, mistakes, the questions you asked, and open notes.

Everything is saved per project in `stdpath("data")/reviewer/<project>/` and kept between sessions.

## Requirements

- Neovim 0.10 or newer
- git
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your `PATH`, logged in). It is used for comments, questions and open-answer grading. Without it, reviewing, notes and choice questions still work.

Claude calls go through `claude -p` and use your own Claude Code account and usage. Code from the files you review is sent to Claude.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "BenjaminRap/nvim-reviewer",
  main = "reviewer",
  cmd = { "Review", "ReviewQuiz", "ReviewProgress", "ReviewNotes", "ReviewAsks" },
  opts = {
    projects = {
      myproject = {
        root = "~/code/myproject",
        remote = "origin",          -- refs are read as <remote>/<branch>
        base = "main",
        stack = { "feature-a", "feature-b", "feature-c" },
        labels = { ["feature-c"] = "feature-c (payments)" }, -- optional display names
        generated = { "^src/generated/" }, -- hidden by default (Lua patterns)
        -- worktrees = "~/code/myproject-review", -- default: next to the repo
        -- quiz_dir = "...",                      -- default: stdpath("data")/reviewer/<name>/quizzes
        -- groups = { ... },                      -- reading order, see below
      },
    },
  },
}
```

For a local copy, use `dir = "~/path/to/nvim-reviewer"` instead of the GitHub name.

Run `:checkhealth reviewer` to check git, Claude Code, the refs of every step and the quiz files.

## How the files are opened

Each step needs a checkout of the code at its head:

- If your main checkout already sits on that commit, it is used.
- Otherwise a **detached git worktree** is created next to the repo (by default `<repo>-review/<n>-<branch>`) the first time you open a file of that step.

Worktrees are local folders, so nothing is pushed. Remove them with `git worktree remove <dir>` when the review is over.

Reviewed files are read-only by default (`readonly = true`). An edit in an earlier step's worktree would go on no branch, and an edit in your main checkout would change your working copy, while the review overlay would stop lining up. Write an "issue" note instead and fix it on the branch. `:ReviewEdit` unlocks the current file when you really need to, for example to try something. Files that the step does not change stay editable.

`:ReviewFetch` runs `git fetch` and moves the step worktrees to their branch's new head, as long as they have no local changes.

## Commands

| Command | What it does |
|---|---|
| `:Review [project]` | Start: opens the file panel (project picked from the current directory if not given) |
| `:ReviewStep {n}` | Go to step n |
| `:ReviewPanel` | Toggle the file panel |
| `:ReviewNext` / `:ReviewPrev` / `:ReviewNextUnread` | Move between the step's files |
| `:ReviewEdit` | Allow changes in the current reviewed file (read-only by default) |
| `:ReviewRead` / `:ReviewReadNext` | Toggle the read mark / mark read and open the next unread file |
| `:ReviewExplain[!]` | Write Claude's comments on the current file if it has none (`!` writes them again) |
| `:ReviewComments` | Show or hide Claude's comments |
| `:ReviewAbout` | Summary, what changed, and commits of the current file |
| `:[range]ReviewNote` | Add a note on the line or range |
| `:ReviewNotes` | List notes: open, resolve, edit, delete |
| `:[range]ReviewAsk` | Ask Claude about the file or the lines |
| `:ReviewAsks` | Questions you asked, with Claude's answers |
| `:ReviewPrepare[!] [n\|final\|all\|stop] [overview\|comments\|quiz]` | Prepare a step in the background (see below) |
| `:ReviewOverview` | Overview of the current step: summary, flows, key concepts, things to check, role of each file |
| `:ReviewQuiz [n\|final\|mistakes]` | Take a quiz, continue it, or retry mistakes |
| `:ReviewProgress` | Everything remembered, with links |
| `:ReviewFetch` | Fetch and update the step worktrees |

## When Claude runs

Claude only runs when you ask, unless you configure otherwise (`ai` options).

- **When you start `:Review`,** the plugin shows what is already prepared for the current step and offers to prepare it: the whole step, only the overview, every step, or not now. With `ai.on_start` you can always prepare, prepare everything, or never ask.
- **Action lines at the top of the panel** (press `<CR>` on a line, or its key):
  - `A` prepares the step, and `D` stops it.
  - `O` opens the step overview, writing it first if needed.
  - `Q` and `gQ` open the step quiz and the final quiz, and offer to write them if they don't exist yet.
  - `c` comments the current file.
- **In a reviewed file,** a hint on the first line tells you when it has no comments yet. `<leader>re` writes them, and asks before writing them again.
- **Automatic comments on open:** set `ai.comment_on_open = true`, plus `ai.prefetch_next` to also comment the next unread file in the background.
- **Your questions and quiz hints** run when you ask them. Open answers are graded by Claude unless `ai.grade_open_answers = false`.

## Preparing a step

`:ReviewPrepare 2` prepares step 2 in the background, in three stages:

1. **Overview.** One call reads the step as a whole: the commits, the file list, the diffs, and any file it wants to open. It writes a summary, the main flows, key concepts, things to check carefully, and one line per file on its role.
2. **Comments on every file.** Files are sent a few at a time (`batch_files`, `batch_chars`), together with the overview, so comments can explain how a file fits with the rest of the step. Claude can open and search other files of the repo at that step.
3. **Quiz.** About 20 to 65 questions depending on the size of the step. Each question is then checked locally: every `file:line` reference must exist at the step's head, and every line of a code snippet must be found in the referenced files. Questions that fail are dropped, and the result says how many.

Details:

- **Stop and resume.** You can stop at any time with `:ReviewPrepare stop` and run it again later. Files already commented for the same diff are skipped.
- **Progress and cost.** The panel shows the progress (`comments 12/40 · $0.84`). The cost is the one Claude Code reports for each call.
- **Single stages.** `:ReviewPrepare 2 comments` runs one stage only.
- **Existing quizzes are kept.** The quiz stage never overwrites an existing quiz unless you add `!`. `!` also writes the overview and comments again.
- **`:ReviewPrepare all`** prepares every step in turn, then the final quiz.
- **`:ReviewPrepare final`** writes the quiz on the whole stack from the step overviews and the final code.
- **In the panel:** `C` on a group, folder or file comments just those files, and `O` shows the overview.

Without preparation, you can comment files one at a time (`c` in the panel, `<leader>re` in the file), or turn on `ai.comment_on_open`. The overview is used as context whenever it exists.

### What Claude sees

| Use | Context |
|---|---|
| Overview | Commits, file list, diffs (capped), read access to the repo at the step's head |
| Comments | The whole file with its changes, the step overview and file roles, read access to the repo |
| Your questions | The file with its changes, the selected lines, the overview, read access to the repo |
| Open-answer grading | The question, the reference answer, the code around the question's references |

## Keys

Every key can be changed or disabled (see [Options](#options)). The panel and quiz defaults leave the keys that move the cursor or search alone (`j` `k` `w` `b` `e` `f` `t` `n` `N` `gg` `G` `/` `?`), so you move in them as in any buffer.

**In a reviewed file** (buffer-local, `keymaps.file`):

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous change |
| `]f` / `[f` | Next / previous file of the step |
| `<leader>rr` | Toggle read |
| `<leader>rn` | Mark read and open the next unread file |
| `<leader>rN` | Add a note (normal or visual) |
| `<leader>ra` | Ask Claude (normal or visual) |
| `<leader>re` | Write Claude's comments (asks before writing them again) |
| `<leader>ri` | About the file: summary, what changed, commits |

**In the panel** (`keymaps.panel`):

| Key | Action |
|---|---|
| `<CR>` `o` | Open a file, fold a group, run an action line |
| `<Tab>` `za` | Fold or unfold a group or folder |
| `x` | Toggle read (file, group or folder) |
| `X` | Mark read and open the next unread file |
| `s` | Reading order / folders |
| `i` | Show or hide generated files |
| `r` | Show or hide read files |
| `p` / `]s` / `[s` | Choose the step / next / previous |
| `c` / `C` | Comment the file / every file of the group or folder |
| `a` | About the file under the cursor |
| `A` / `D` | Prepare the step / stop |
| `O` | Step overview |
| `Q` / `gQ` | Step quiz / final quiz |
| `P` / `gn` | Progress / notes |
| `gc` | Show or hide Claude's comments |
| `q` / `g?` | Close / help |

**In a quiz** (`keymaps.quiz`): `a`–`f` pick a choice, or `<Space>` on a choice line; `<CR>` check, then next; `i` write an open answer; `d` don't know; `gh` hint; `x` ask Claude why; `1`–`4` open the code a question refers to; `J` / `K` next / previous; `r` retry; `o` results by level; `+` `~` `-` grade yourself when Claude cannot; `q` close (`:ReviewQuiz` resumes).

**In floats** (`keymaps.float`, `keymaps.input`, `keymaps.progress`): `q` or `<Esc>` closes. In an input box, `<C-s>` (or `<CR>` in normal mode) saves and `q` / `<Esc>` cancels.

## Options

```lua
require("reviewer").setup({
  projects = { ... },
  claude = {
    cmd = "claude",
    models = {                  -- model per use (see "Models" below)
      overview = "opus", comments = "sonnet", quiz = "opus",
      final = "opus", ask = "opus", grade = "sonnet",
    },
    model = nil,                -- for any use without its own model; nil = Claude Code's default
    fallback_model = "sonnet",  -- if the chosen model is busy or not on your plan
    explain_tools = "Read,Grep,Glob", -- tools allowed when commenting ("" = none, faster and cheaper)
    ask_tools = "Read,Grep,Glob",     -- read-only tools for questions
    grade_tools = "",
    prepare_tools = "Read,Grep,Glob", -- for :ReviewPrepare
    batch_files = 6,                  -- files per call when preparing
    batch_chars = 60000,
    max_parallel = 2,
    timeout_ms = 600000,
  },
  ai = {
    on_start = "ask",           -- on :Review: "ask", "step" (prepare it), "all", or "never"
    comment_on_open = false,    -- comment a file automatically the first time it is opened
    prefetch_next = false,      -- then also comment the next unread file
    offer_missing_quiz = true,  -- offer to write a quiz you open that does not exist yet
    grade_open_answers = true,  -- false: you grade open answers yourself
  },
  show_comments = true,         -- Claude's comments above the code
  show_removed = true,          -- removed lines shown in place, in red
  readonly = true,              -- reviewed files cannot be changed (:ReviewEdit unlocks one)
  hide_generated = true,
  order = "reading",            -- or "tree"
  comment_width = 100,          -- maximum width of a comment box
  panel = {
    position = "left",          -- or "right"
    width = 48,
    icons = true,               -- mini.icons or nvim-web-devicons, when installed
    show_actions = true,        -- action lines at the top
    show_file_summary = true,   -- summary of the current file at the bottom
  },
  float = {
    border = "rounded",         -- any 'winborder' style
    width = 0.8, height = 0.8,  -- fraction of the editor, or columns/lines when > 1
    text_width = 96,            -- wrap width of text in floats
  },
  symbols = {
    read = "x", unread = " ", partly_read = "-",
    fold_open = "▾", fold_closed = "▸",
    added = "+", removed = "-", removed_prefix = "- ",
    comment = "✦", pending = "…",
    note = "●", question = "?", issue = "!", answer = "✦",
    action = "▶", stop = "■",
  },
  keymaps = {
    -- a string, a list of strings, or false to disable; only what you set changes
    file = { next_change = "]c", prev_change = "[c", next_file = "]f", prev_file = "[f",
             toggle_read = "<leader>rr", read_next = "<leader>rn", note = "<leader>rN",
             ask = "<leader>ra", explain = "<leader>re", about = "<leader>ri" },
    panel = { open = { "<CR>", "o" }, fold = { "<Tab>", "za" }, toggle_read = "x", read_next = "X",
              toggle_order = "s", toggle_generated = "i", toggle_hide_read = "r",
              pick_step = "p", next_step = "]s", prev_step = "[s",
              explain = "c", explain_group = "C", about = "a", prepare = "A", stop = "D",
              overview = "O", quiz = "Q", final_quiz = "gQ", progress = "P", notes = "gn",
              toggle_comments = "gc", close = "q", help = "g?" },
    quiz = { choices = "abcdef", toggle_choice = "<Space>", check = "<CR>", answer = "i",
             dont_know = "d", next = "J", prev = "K", retry = "r", hint = "gh", explain = "x",
             overview = "o", refs = { "1", "2", "3", "4" },
             self_correct = "+", self_partial = "~", self_wrong = "-", close = { "q", "<Esc>" } },
    progress = { open = "<CR>", retry_mistakes = "m", notes = "gn", asks = "A" },
    float = { close = { "q", "<Esc>" } },
    input = { submit = "<C-s>", submit_normal = "<CR>", cancel = { "q", "<Esc>" } },
  },
  generated = { "package%-lock%.json$", "yarn%.lock$", "pnpm%-lock%.yaml$" },
  groups = {                    -- reading order; first matching group wins, `order` sorts them
    { label = "Tests", order = 90, patterns = { "/tests?/", "%.test%." } },
    { label = "Database", order = 10, patterns = { "^prisma/", "migrations?/" } },
    -- ...
    { label = "Other", order = 95, patterns = { "" } },
  },
})
```

### Models

Each use of Claude has its own model. The defaults keep the strongest model where there are few calls and accuracy matters, and use a cheaper one where there are many calls:

| Use | Default | Why |
|---|---|---|
| `overview` | `opus` | One call per step; its summary is the context for every other call |
| `comments` | `sonnet` | One call per file or batch of files, so most of the calls |
| `quiz` | `opus` | One call per step; questions must be exact |
| `final` | `opus` | The final quiz on the whole stack |
| `ask` | `opus` | Your questions and quiz hints |
| `grade` | `sonnet` | Short check of an open answer against a reference answer |

Values are aliases accepted by `claude --model` (`opus`, `sonnet`, `haiku`) or full model names.

- **Changing one use:** set it, e.g. `models = { comments = "haiku" }`; the other uses keep their defaults.
- **Using your Claude Code default:** set a use to `false`.
- **One model for everything:** set `claude.model` without `models`.
- **If a model is busy or not on your plan,** `fallback_model` is used instead.

For example, to keep the defaults but put the panel on the right, use `<Space>` to tick files and disable the letter keys in quizzes:

```lua
opts = {
  panel = { position = "right" },
  keymaps = {
    panel = { toggle_read = "<Space>" },
    quiz = { choices = "" }, -- pick with <Space> on the choice line instead
  },
}
```

### Highlight groups

Every colour comes from a highlight group linked to a standard one, so the plugin follows your colorscheme. Override any of them with `vim.api.nvim_set_hl(0, "ReviewerAdd", { ... })`.

| Group | Default link | Used for |
|---|---|---|
| `ReviewerAdd` / `ReviewerAddSign` | `DiffAdd` / `Added` | Added lines and their sign |
| `ReviewerDelete` / `ReviewerDeleteSign` | `DiffDelete` / `Removed` | Removed lines and their sign |
| `ReviewerComment` / `ReviewerCommentTitle` | `DiagnosticVirtualTextInfo` / `DiagnosticInfo` | Claude's comments |
| `ReviewerNote` / `ReviewerQuestion` / `ReviewerIssue` | `DiagnosticVirtualText{Warn,Hint,Error}` | Notes by kind |
| `ReviewerHeader` / `ReviewerGroup` | `Title` | Panel title and groups |
| `ReviewerAction` | `Function` | Panel action lines |
| `ReviewerRead` / `ReviewerDim` | `Comment` | Read files, secondary text |
| `ReviewerCurrent` | `CursorLine` | The file you are on |
| `ReviewerOk` / `ReviewerPartial` / `ReviewerBad` | `DiagnosticOk` / `Warn` / `Error` | Results and warnings |

## Quiz files

Quizzes are JSON files named `quiz-*.json` in the project's `quiz_dir`. Each step quiz has the id `step<n>`, and `final` is the quiz on the whole stack:

```json
{
  "id": "step1",
  "title": "feature-a",
  "ref": "origin/feature-a",
  "questions": [
    {
      "id": "s1-q01",
      "level": 1,
      "topic": "Scope",
      "type": "single",
      "prompt": "What does this step add?",
      "code": "optional snippet",
      "codeLang": "typescript",
      "choices": ["...", "...", "...", "..."],
      "answer": [1],
      "reference": "Short model answer (the full model answer for open questions)",
      "explanation": "Why",
      "refs": [{ "path": "src/app.ts", "line": 12, "endLine": 20 }]
    }
  ]
}
```

- **`type`** is `single`, `multi` or `open`. `answer` holds 0-based indexes and is omitted for `open`.
- **`level`** goes from 1 (architecture) to 5 (line-level details).
- **Question ids** must be unique across all quizzes of a project, because results are saved by id.
- **Refs** point to the code at the step's head.

`:ReviewPrepare` writes these files for you. You can also write them yourself or with another tool; they go through the same checks only when written by `:ReviewPrepare`.

## Saved data

`stdpath("data")/reviewer/<project>/`:

- `state.json`: read marks, notes, quiz attempts with their history, questions asked to Claude
- `explain.json`: step overviews and Claude's comments per file, tied to the diff they were written for (they are written again if the diff changes)
- `quizzes/`: the default place for quiz files

## License

MIT, see [LICENSE](LICENSE).
