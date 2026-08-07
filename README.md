# Flashcards for KOReader

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%205.5%20%7C%20LuaJIT-blue?logo=lua)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-green)
![Status](https://img.shields.io/badge/Status-Beta-brightgreen)

A pure-Lua KOReader plugin that quizzes you on your `flashcards.md` notes directly on the Kobo — the e-ink counterpart of the desktop `~/.local/bin/quiz.py` tool.

It reads the **same files** the desktop quiz parses:

```
---
Q: What is the derivative of sin(x)?
A: cos(x)
---
Q: Next question...
A: ...answer
```

and understands the same corpus: `---`-separated blocks, `Q:`/`A:` lines with multi-line continuation, CRLF, blank lines between cards.

## Features

* **Same format, same files**: full parity with the desktop quiz tool's parser (plus one forgiving extension: indented `Q:`/`A:` lines are accepted).
* **Theme discovery**: recursively finds every `flashcards.md` under the notes folder; each containing folder is a theme, plus an "All Themes Combined" deck — just like the desktop tool.
* **E-ink friendly flow**: pick a theme → pick a deck length (all / 10 / 25 / 50) → reveal each answer → self-score with two taps ("Got it" / "Missed"). Long questions scroll.
* **Missed-card review**: the cards you missed are saved; "Review Missed Cards" re-quizzes exactly those, and a finished quiz offers "Review Missed" immediately.
* **Works with syncnotes**: the default notes root matches the folder `syncnotes.koplugin` fills, so synced flashcards are quizzed with zero configuration.

## Installation

1. Copy the `flashcards.koplugin` folder to the Kobo:

   ```bash
   /mnt/kobo/.adds/koreader/plugins/
   ```

2. Restart KOReader, enable the plugin via **Tools → Plugin management**.
3. **Tools → Flashcards → Start Quiz**.

If your notes live elsewhere, use **Tools → Flashcards → Set Notes Folder** (default: `<koreader data>/notes`, the syncnotes download root).

## Usage

* **Start Quiz** — theme menu (each theme shows its card count), then a deck-length menu.
* **Reveal Answer** — shows the answer and swaps the buttons for **Got it** / **Missed**.
* **Quit** — leaves mid-quiz (with a confirm) and shows a partial summary.
* **Summary** — score, percentage, and a **Review Missed** button when anything was missed.
* The physical Back key on a card also asks to quit; on the summary it closes.

## Format

```text
---
Q: question — any text, can
   span multiple lines
A: answer, also multi-line capable
---
```

* Blocks are split on the literal line `---`.
* A block needs both a `Q:` and an `A:` (an indented variant is accepted) to become a card; otherwise it is skipped.
* Interior blank lines inside a card are preserved (matching the desktop parser).
* Markdown/LaTeX inside cards is shown as-is — the plugin renders plain text, it does not typeset math (see `markdownreader.koplugin` for reading rendered notes).

## Local development

The logic is split out of the UI so it runs on a PC:

```bash
lua run_busted_tests.lua                 # unit tests (parser, quiz engine, CLI)
lua tools/flashcards-cli.lua tests/fixtures/notes          # interactive
lua tools/flashcards-cli.lua <some>.md --auto              # headless smoke test
```

`parser.lua` (file → cards) and `quiz.lua` (shuffle/score/missed state machine) have **no KOReader dependencies**; `main.lua` is a thin adapter over KOReader widgets and is exercised on the device.

## Cleaning up

**Tools → Flashcards → Clear Quiz History** forgets the saved missed-card set. The plugin writes nothing else: no caches, no generated files, no changes to your `.md` files.
