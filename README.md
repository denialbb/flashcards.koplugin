# Flashcards Plugin for KOReader

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%205.5%20%7C%20LuaJIT-blue?logo=lua)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-green)
![Status](https://img.shields.io/badge/Status-Beta-brightgreen)

KOReader plugin that discovers, parses, and administers interactive flashcard study sessions from Markdown notes.

## File Format Specification

The plugin parses `flashcards.md` files structured into discrete card blocks:

```text
---
Q: What is the time complexity of binary search?
A: O(log n)
---
Q: State the fundamental theorem of calculus:
   Part 1 and Part 2.
A: Part 1: If f is continuous on [a,b] and F(x) = \int_a^x f(t)dt, then F'(x) = f(x).
   Part 2: \int_a^b f(x)dx = F(b) - F(a).
---
```

### Parsing Rules

1. **Card Delimiter**: Blocks are partitioned on literal `---` boundary lines.
2. **Field Prefixes**: Each block must contain a question line (`Q: `) and an answer line (`A: `). Leading whitespace/indentation on prefix lines is accepted.
3. **Multi-line Continuation**: Lines following `Q:` or `A:` prior to the next prefix or boundary line are treated as multi-line continuations.
4. **Text Representation**: Plain text rendering without LaTeX typesetting (for rendered mathematical prose, use `markdownreader.koplugin`).

## Features & Session State Flow

- **Theme Discovery**: Recursively scans the configured note directory for `flashcards.md` files. Each containing folder is registered as an individual Theme, with an aggregate "All Themes Combined" option.
- **Deck Sizing**: Configurable session sizes (`All`, `10`, `25`, `50`).
- **Interactive Quiz Flow**:
  1. Displays question prompt.
  2. User taps **Reveal Answer**.
  3. User records recall evaluation (**Got it** / **Missed**).
  4. Session concludes with score summary and percentage calculation.
- **Missed Deck Review**: Flashcards evaluated as missed during a session are stored in memory for targeted re-testing.

## Installation & Configuration

1. Copy `flashcards.koplugin` to the KOReader plugins directory:
   ```bash
   cp -r flashcards.koplugin /mnt/kobo/.adds/koreader/plugins/
   ```
2. Restart KOReader and enable the plugin under **Tools → Plugin management**.
3. Configure note root under **Tools → Flashcards → Set Notes Folder** (defaults to `<koreader data>/notes`).
4. Start a session via **Tools → Flashcards → Start Quiz**.

## Diagnostics & Logging

- **Logging**: Execution and error events are written to `<koreader_settings>/flashcards.log` and the system `crash.log`.
- **UI Error Trapping**: Handlers catch exceptions and display actionable dialogs via `InfoMessage` widgets.

## Development & Test Harness

The parsing (`parser.lua`) and quiz state machine (`quiz.lua`) logic are decoupled from KOReader UI widgets:

```bash
# Run unit test suite
lua run_busted_tests.lua

# Run interactive CLI session off-device
lua tools/flashcards-cli.lua tests/fixtures/notes

# Run headless automated smoke test
lua tools/flashcards-cli.lua tests/fixtures/notes --auto
```

## State Management

Access **Tools → Flashcards → Clear Quiz History** to reset recorded missed flashcard sets.

