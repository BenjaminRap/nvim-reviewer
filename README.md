# nvim-reviewer

Review the changes of a branch in Neovim, file by file, in your real editor (LSP, search and your usual mappings all work).

`:Review main feature` shows what `feature` changes compared with `main`. When branches are built on top of each other, review them one pair at a time: `:Review main feature-a`, then `:Review feature-a feature-b`.

- **Full file with its changes.** Each file opens as a normal buffer, read-only by default. Added lines are highlighted and removed lines are shown in place, in red. The file itself is never modified.
- **A review prepared in advance.** `:Review prepare` has Claude read the changes as a whole (overview, main flows, role of each file), comment every file in batches with that overview as context, and write a quiz that is checked locally.
- **Side by side, if you prefer.** `:Review split` (or `layout = "split"`) shows the version before the change next to the file, in Neovim's own diff mode.
- **Claude's comments** above each change block, written once per file and saved.
- **An oil-like browser.** Move through the changed files one folder at a time, like oil (`<CR>`, `-`, `_`), or see them all in reading order (database → shared → backend → frontend → tests). Read marks are text: tick `[ ]` → `[x]` with any edit, `:w` saves. Deleted and renamed files are listed too.
- **Your own notes** on a line, selected lines or a whole changed block, shown with a `✎` on a line of its own above the code and listed in the quickfix list (`:Review notes`).
- **Questions to Claude** about a file or selected lines. Claude runs in the reviewed checkout with read-only tools, so it can open any file of the repo. Questions and answers are saved.
- **Quizzes**, from the big picture down to single lines. Choice questions are graded locally; Claude grades open answers against a reference answer. Mistakes are saved and can be retried.
- **Progress view.** Shows every review of the repository with files read and quiz results, your mistakes, and the questions you asked.

Everything is saved per repository in `stdpath("data")/reviewer/<repo>/` and kept between sessions.

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
  cmd = "Review",
  opts = {
    -- nothing is required; settings per repository are optional:
    repos = {
      myproject = {                        -- the repository's folder name (or set `root`)
        generated = { "^src/generated/" }, -- hidden by default (Lua patterns)
        -- base = "develop",               -- default base for `:Review <branch>`
        -- groups = { ... },               -- reading order, see Options
      },
    },
  },
}
```

For a local copy, use `dir = "~/path/to/nvim-reviewer"` instead of the GitHub name.

`:help reviewer` has the full documentation inside Neovim. Run `:checkhealth reviewer` from inside a repository to check git, Claude Code, the default base branch and the last review.

## Starting a review

From anywhere inside a git repository:

- **`:Review main feature`** reviews `feature` compared with `main`.
- **`:Review feature`** compares `feature` with the default base (`main`, or `base` in the options).
- **`:Review`** with no argument offers to continue your last review, or lets you pick the two branches.
- **`gB` in the browser** switches to other branches.

Branch names complete with `<Tab>`.

Branch names are read on the remote: `feature` means `origin/feature` when it exists, so you review what was pushed. A name that exists only locally is used as is, and `refs/heads/feature` forces your local branch. Run `:Review fetch` to get the latest commits.

### Where the files come from

The files of a review must exist on disk at the version of the reviewed branch, so that your LSP, search and file explorer work on them:

- **Your own checkout** is used when it is already on that commit.
- **Otherwise, one hidden checkout** per repository (a git worktree in `stdpath("cache")/reviewer/<repo>`, see `worktree_dir`) is created the first time, then moved to the reviewed branch at each new review. It is on no branch, so nothing you do there can affect your branches.

`:Review clean` removes the hidden checkout; your progress is kept.

**Dependencies for the LSP.** The hidden checkout has no `node_modules`, so your LSP would not find the types of external packages. The plugin installs them there from the lockfile (`npm ci`, `pnpm install` or `yarn install`), with install scripts skipped so no code of the reviewed branch runs, and again only when the lockfile changes. It never installs anything in your own checkout. This can take a few minutes and some disk space; `deps = { install = false }` turns it off.

Reviewed files are read-only by default (`readonly = true`). An edit in the hidden checkout would be on no branch and lost at the next review, and an edit in your own checkout would change your working copy, while the review overlay would stop lining up. Fix what you find on the branch itself. `:Review edit` unlocks the current file when you really need to, for example to try something. Files the review does not change stay editable.

## Commands

There is one command, `:Review`; everything else is a subcommand (`:Review <Tab>` lists them, with the branch names).

| Command | What it does |
|---|---|
| `:Review [base] [branch]` | Start a review (see above) and open the browser |
| `:Review start [base] branch` | The same, for a branch named like a subcommand |
| `:Review browse [folder]` | Open the browser (optionally on a folder) |
| `:Review split` | Switch between inline changes and side by side |
| `:Review next` / `:Review prev` / `:Review next-unread` | Move between the files of the review |
| `:Review edit` | Allow changes in the current reviewed file (read-only by default) |
| `:Review read` / `:Review read-next` | Toggle the read mark / mark read and open the next unread file |
| `:Review[!] explain` | Write Claude's comments on the current file if it has none (`!` writes them again) |
| `:Review comments` | Show or hide Claude's comments |
| `:Review keys` | Show or hide the key bar at the bottom |
| `:Review about` | Summary, what changed, and commits of the current file |
| `:[range]Review ask` | Ask Claude about the file or the lines |
| `:Review asks` | Questions you asked, with Claude's answers |
| `:[range]Review note` | Your note on this line or the lines in range; on a note, edit it (empty deletes it) |
| `:Review notes` | Every note of the review, in the quickfix list |
| `:Review[!] prepare [overview\|comments\|quiz\|stop]` | Prepare the review in the background (see below) |
| `:Review overview` | Overview of the changes: summary, flows, key concepts, things to check, role of each file |
| `:Review quiz [list\|mistakes]` | Quiz of the current review; `list` to pick another review's quiz; `mistakes` to retry them all |
| `:Review progress` | Every review of the repository and everything remembered, with links |
| `:Review fetch` | `git fetch`, then show the latest commits of the reviewed branches |
| `:Review clean` | Remove the hidden checkout |

## When Claude runs

Claude only runs when you ask, unless you configure otherwise (`ai` options).

- **When you start a review,** the plugin shows what is already prepared and offers to prepare it: everything, only the overview, or not now. With `ai.on_start` you can always prepare or never ask.
- **Keys in the browser** (`g?` lists them):
  - `gA` prepares the review, and `gS` stops it.
  - `gO` opens the overview, writing it first if needed.
  - `gQ` opens the quiz, and offers to write it if it doesn't exist yet.
  - `gC` comments the file under the cursor.
- **In a reviewed file,** a hint on the first line tells you when it has no comments yet. `<leader>re` writes them, and asks before writing them again.
- **Automatic comments on open:** set `ai.comment_on_open = true`, plus `ai.prefetch_next` to also comment the next unread file in the background.
- **Your questions and quiz hints** run when you ask them. Open answers are graded by Claude unless `ai.grade_open_answers = false`.

## Preparing a review

`:Review prepare` prepares the current review in the background, in three stages:

1. **Overview.** One call reads the changes as a whole: the commits, the file list, the diffs, and any file it wants to open. It writes a summary, the main flows, key concepts, things to check carefully, and one line per file on its role.
2. **Comments on every file.** Files are sent a few at a time (`batch_files`, `batch_chars`), together with the overview, so comments can explain how a file fits with the rest. Claude can open and search other files of the repo.
3. **Quiz.** About 20 to 65 questions depending on the size of the changes. Each question is then checked locally: every `file:line` reference must exist on the reviewed branch, and every line of a code snippet must be found in the referenced files. Questions that fail are dropped, and the result says how many.

Details:

- **Stop and resume.** You can stop at any time with `:Review prepare stop` and run it again later. Files already commented for the same diff are skipped.
- **Progress and cost.** The browser's title bar shows the progress (`comments 12/40 · $0.84`). The cost is the one Claude Code reports for each call.
- **Single stages.** `:Review prepare comments` runs one stage only.
- **Existing quizzes are kept.** The quiz stage never overwrites an existing quiz unless you add `!`. `!` also writes the overview and comments again.
- **A quiz on several branches at once:** review the whole range, e.g. `:Review main feature-c`, and take its quiz.
- **In the browser:** `gF` on a folder, group or file comments just those files, and `gO` shows the overview.

Without preparation, you can comment files one at a time (`gC` in the browser, `<leader>re` in the file), or turn on `ai.comment_on_open`. The overview is used as context whenever it exists.

### What Claude sees

| Use | Context |
|---|---|
| Overview | Commits, file list, diffs (capped), read access to the repo at the reviewed branch |
| Comments | The whole file with its changes, the overview and file roles, read access to the repo |
| Your questions | The file with its changes, the selected lines, the overview, read access to the repo |
| Open-answer grading | The question, the reference answer, the code around the question's references |

## Keys

Every key can be changed or disabled (see [Options](#options)). The browser and quiz defaults leave the keys that move the cursor or search alone (`j` `k` `w` `b` `e` `f` `t` `n` `N` `gg` `G` `/` `?`), so you move in them as in any buffer.

**In a reviewed file** (buffer-local, `keymaps.file`):

| Key | Action |
|---|---|
| `↓` / `↑` (or `]c` / `[c`) | Next / previous change |
| `→` / `←` (or `]f` / `[f`) | Next / previous file of the review |
| `<leader>rr` | Toggle read |
| `<leader>rn` | Mark read and open the next unread file |
| `<leader>ra` | Ask Claude (normal or visual) |
| `<leader>re` | Write Claude's comments (asks before writing them again) |
| `<leader>ri` | About the file: summary, what changed, commits |
| `-` | Open the browser on the file's folder |
| `<leader>rs` | Inline changes / side by side |
| `<leader>rc` | Claude's comments as boxes / as markers (`<leader>rh` opens one) |
| `<leader>rh` | Claude's comment of the code under the cursor; press again to go into it (`q` or `<Esc>` to leave) |
| `<leader>rm` | Your note on this line (visual: on the selected lines); on a note, edit it; saving it empty deletes it |
| `g?` | Every key, in a float |

**Key bar.** While you are in a reviewed file, the browser or the quiz, a bar at the bottom of the screen lists their keys, like lazygit. It is a real window, so it never hides code, and focus never stays in it. `key_hints = false` turns it off, `:Review keys` hides or shows it. `key_bar` chooses what it shows, by keymap option name: `hide` leaves out keys you already know (from oil, for example), `show` adds keys that are only in `g?` (see the options below).

**In the browser** (`keymaps.browser`). Its text is editable for read marks, so every editing and moving key works as in any buffer; the plugin uses oil's keys and `g` keys:

| Key | Action |
|---|---|
| `<CR>` | Enter a folder / open a file in this window |
| `<C-s>` / `<C-h>` / `<C-t>` | Open in a vertical split / horizontal split / new tab |
| `<C-p>` | Preview, staying in the browser |
| `-` / `_` | Parent folder / root of the review |
| `gs` | One folder at a time / all files in reading order |
| `g.` / `gG` | Show or hide unchanged files / generated files |
| `<C-l>` | Refresh |
| `gC` / `gF` | Claude's comments on the file / on every file of the folder |
| `gK` | About the file under the cursor |
| `gA` / `gS` | Prepare the review / stop |
| `gO` / `gQ` | Overview of the changes / quiz |
| `gL` | Progress |
| `gN` | Every note of the review, in the quickfix list |
| `<C-c>` | Back to the file shown before the browser (like oil's close) |
| `gB` | Review other branches |
| `g?` | Help |
| edit `[ ]` ↔ `[x]`, then `:w` | Save read marks (a folder's box marks everything inside it) |

In a reviewed file, `-` (`keymaps.file.browse`) opens the browser on the file's folder with the cursor on it, like oil.

**In a quiz** (`keymaps.quiz`): `a`–`f` pick a choice, or `<Space>` on a choice line; `<CR>` check, then next; `i` write an open answer; `d` don't know; `gh` hint; `x` ask Claude why; `1`–`4` open the code a question refers to; `J` / `K` next / previous; `r` retry; `o` results by level; `+` `~` `-` grade yourself when Claude cannot; `q` close (`:Review quiz` resumes).

**In floats** (`keymaps.float`, `keymaps.input`, `keymaps.progress`): `q` or `<Esc>` closes. In an input box, `<C-s>` (or `<CR>` in normal mode) saves and `q` / `<Esc>` cancels.

## Options

```lua
require("reviewer").setup({
  repos = { ... },                -- optional settings per repository (see Install)
  remote = "origin",              -- branch names are read as <remote>/<name> when that exists
  base = "main",                  -- default base for :Review <branch>
  worktree_dir = vim.fn.stdpath("cache") .. "/reviewer", -- where the hidden checkouts go
  claude = {
    cmd = "claude",
    models = {                  -- model per use (see "Models" below)
      overview = "opus", comments = "sonnet", quiz = "opus",
      ask = "opus", grade = "sonnet",
    },
    model = nil,                -- for any use without its own model; nil = Claude Code's default
    fallback_model = "sonnet",  -- if the chosen model is busy or not on your plan
    explain_tools = "Read,Grep,Glob", -- tools allowed when commenting ("" = none, faster and cheaper)
    ask_tools = "Read,Grep,Glob",     -- read-only tools for questions
    grade_tools = "",
    prepare_tools = "Read,Grep,Glob", -- for :Review prepare
    batch_files = 6,                  -- files per call when preparing
    batch_chars = 60000,
    max_parallel = 2,
    timeout_ms = 600000,
  },
  ai = {
    on_start = "ask",           -- when a review starts: "ask", "step" (prepare it), or "never"
    comment_on_open = false,    -- comment a file automatically the first time it is opened
    prefetch_next = false,      -- then also comment the next unread file
    offer_missing_quiz = true,  -- offer to write a quiz you open that does not exist yet
    grade_open_answers = true,  -- false: you grade open answers yourself
  },
  show_comments = true,         -- Claude's comments above the code
  comments = "inline",          -- or "marker": one line above the code, <leader>rh opens the comment
  key_hints = true,             -- the key bar at the bottom
  key_bar = { hide = {}, show = {} }, -- per buffer: { browser = { "open", "parent" } }
  inline_changes = true,        -- changed words drawn stronger inside a changed line
  colors = "colorscheme",       -- or "github", or "vivid": green and red mixed into your background
  show_removed = true,          -- removed lines shown in place, in red
  readonly = true,              -- reviewed files cannot be changed (:Review edit unlocks one)
  layout = "inline",            -- or "split": before | after, in Neovim's diff mode
  deps = {                      -- dependencies of the hidden checkout, for the LSP
    install = true, ignore_scripts = true, cmd = nil,
  },
  hide_generated = true,
  comment_width = 100,          -- maximum width of a comment box
  browser = {
    view = "folders",           -- or "reading" (all files in reading order)
    icons = true,               -- mini.icons or nvim-web-devicons, when installed
    show_unchanged = false,     -- also list unchanged files, dimmed (g. toggles)
  },
  float = {
    border = "rounded",         -- any 'winborder' style
    width = 0.8, height = 0.8,  -- fraction of the editor, or columns/lines when > 1
    text_width = 96,            -- wrap width of text in floats
  },
  symbols = {
    read = "x", unread = " ", partly_read = "-",
    added = "+", removed = "-", removed_prefix = "- ",
    comment = "✦", pending = "…", note = "✎",
  },
  keymaps = {
    -- a string, a list of strings, or false to disable; only what you set changes
    file = { next_change = { "<Down>", "]c" }, prev_change = { "<Up>", "[c" }, next_file = { "<Right>", "]f" }, prev_file = { "<Left>", "[f" },
             toggle_read = "<leader>rr", read_next = "<leader>rn",
             ask = "<leader>ra", explain = "<leader>re", about = "<leader>ri", browse = "-",
             toggle_split = "<leader>rs", comments_style = "<leader>rc",
             show_comment = "<leader>rh", note = "<leader>rm", help = "g?" },
    browser = { open = "<CR>", open_vsplit = "<C-s>", open_split = "<C-h>", open_tab = "<C-t>",
                preview = "<C-p>", parent = "-", root = "_", refresh = "<C-l>",
                toggle_view = "gs", toggle_unchanged = "g.", toggle_generated = "gG",
                explain = "gC", explain_folder = "gF", about = "gK",
                prepare = "gA", stop = "gS", overview = "gO", quiz = "gQ",
                progress = "gL", new_review = "gB", notes = "gN", close = "<C-c>", help = "g?" },
    quiz = { choices = "abcdef", toggle_choice = "<Space>", check = "<CR>", answer = "i",
             dont_know = "d", next = "J", prev = "K", retry = "r", hint = "gh", explain = "x",
             overview = "o", refs = { "1", "2", "3", "4" },
             self_correct = "+", self_partial = "~", self_wrong = "-", close = { "q", "<Esc>" } },
    progress = { open = "<CR>", retry_mistakes = "m", asks = "A" },
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
| `overview` | `opus` | One call per review; its summary is the context for every other call |
| `comments` | `sonnet` | One call per file or batch of files, so most of the calls |
| `quiz` | `opus` | One call per review; questions must be exact |
| `ask` | `opus` | Your questions and quiz hints |
| `grade` | `sonnet` | Short check of an open answer against a reference answer |

Values are aliases accepted by `claude --model` (`opus`, `sonnet`, `haiku`) or full model names.

- **Changing one use:** set it, e.g. `models = { comments = "haiku" }`; the other uses keep their defaults.
- **Using your Claude Code default:** set a use to `false`.
- **One model for everything:** set `claude.model` without `models`.
- **If a model is busy or not on your plan,** `fallback_model` is used instead.

For example, to open the browser from reviewed files with `<leader>e` (like an `:Oil` mapping) and pick quiz choices only with `<Space>`:

```lua
opts = {
  keymaps = {
    file = { browse = "<leader>e" },
    quiz = { choices = "" }, -- pick with <Space> on the choice line instead
  },
}
```

### Highlight groups

Every colour comes from a highlight group linked to a standard one, so the plugin follows your colorscheme. Override any of them with `vim.api.nvim_set_hl(0, "ReviewerAdd", { ... })`.

`colors = "github"` uses GitHub's diff colours instead (light or dark, from `background`). `colors = "vivid"` mixes a bright green and red into your colorscheme's background, so changes stand out on any background. Inside a changed line, the changed words are drawn a little stronger, as on GitHub; `inline_changes = false` turns that off.

| Group | Default link | Used for |
|---|---|---|
| `ReviewerAdd` / `ReviewerAddSign` | `DiffAdd` / `Added` | Added lines and their sign |
| `ReviewerDelete` / `ReviewerDeleteSign` | `DiffDelete` / `Removed` | Removed lines and their sign |
| `ReviewerKey` / `ReviewerKeyDesc` / `ReviewerKeyBar` | `Special` / `Comment` / `NormalFloat` | The key bar |
| `ReviewerAddText` / `ReviewerDeleteText` | the line colour blended with `Added` / `Removed` | Changed words inside a changed line |
| `ReviewerComment` / `ReviewerCommentTitle` | `DiagnosticVirtualTextInfo` / `DiagnosticInfo` | Claude's comments |
| `ReviewerHeader` / `ReviewerGroup` | `Title` | Titles and reading-order groups |
| `ReviewerRead` / `ReviewerDim` | `Comment` | Read files, secondary text |
| `ReviewerNote` | `DiagnosticHint` | Your notes |
| `ReviewerCurrent` | `CursorLine` | The file you are on |
| `ReviewerOk` / `ReviewerPartial` / `ReviewerBad` | `DiagnosticOk` / `Warn` / `Error` | Results and warnings |

## Quiz files

Quizzes are JSON files named `quiz-<base>..<branch>.json` in the repository's `quiz_dir`. The `id` of a quiz is its review, `<base>..<branch>`:

```json
{
  "id": "main..feature-a",
  "title": "main → feature-a",
  "ref": "origin/feature-a",
  "questions": [
    {
      "id": "s1-q01",
      "level": 1,
      "topic": "Scope",
      "type": "single",
      "prompt": "What does this branch add?",
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
- **Refs** point to the code of the reviewed branch.

`:Review prepare` writes these files for you. You can also write them yourself or with another tool; they go through the same checks only when written by `:Review prepare`.

## Saved data

`stdpath("data")/reviewer/<project>/`:

- `state.json`: read marks, your notes, quiz attempts with their history, questions asked to Claude
- `explain.json`: overviews of each review and Claude's comments per file, tied to the diff they were written for (they are written again if the diff changes)
- `quizzes/`: the default place for quiz files

## Development

`make test` (or `tests/run.sh`) runs the tests headless. They build a small git repository with a fake remote and check the plugin against it: branches and statuses, the hidden checkout, the browser and its read marks, the overlay, side by side, quizzes and saved data. Claude is replaced by a fake, so the tests use no Claude usage. `SPEC=browser tests/run.sh` runs one file.

## License

MIT, see [LICENSE](LICENSE).
