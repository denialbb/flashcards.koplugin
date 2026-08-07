--[[--
Flashcard parser. Pure Lua, no KOReader dependencies.

Understands the same corpus as the desktop quiz tool (~/.local/bin/quiz.py):

    ---
    Q: question text
    A: answer text
    ---
    Q: next question
    A: next answer

* Blocks are delimited by the literal line `---`.
* A block needs both a `Q:` and an `A:` line (or indented variant) to become a
  card; a block missing either is skipped.
* Lines after a `Q:`/`A:` line are appended to it, so multi-line questions and
  answers work. Blank lines inside a card are preserved.
* Leading/trailing blank space is trimmed from each block and from the final
  question/answer, so cards are not polluted by surrounding blank lines.

One deliberate, backwards-compatible relaxation vs. the desktop parser: `Q:`/
`A:` may be indented (the desktop tool requires them flush left). That cannot
misparse a file that works there — a flush-left line is handled identically —
and it rescues sloppily-indented files.
]]

local Parser = {}

--[[
Split a string on every literal "---" occurrence (plain search, so the dashes
are not interpreted as a Lua pattern). Empty strings are kept; callers skip
them after trimming. Matches Python's `content.split("---")`.
--]]
local function splitBlocks(content)
    local parts = {}
    local start = 1
    while true do
        local pos = content:find("---", start, true)
        if not pos then
            parts[#parts + 1] = content:sub(start)
            break
        end
        parts[#parts + 1] = content:sub(start, pos - 1)
        start = pos + 3
    end
    return parts
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--[[
Parse one (already trimmed) block into a single card { question, answer }.
Returns nil when the block has no usable question or answer.
]]
local function parseBlock(text)
    local q, a = {}, {}
    local mode -- nil | "Q" | "A"
    -- Split into lines keeping empty ones, so interior blank lines inside a
    -- card are preserved (the desktop tool's strip() keeps them too). The
    -- trailing "\n" makes the last line surface even without a newline.
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        -- Tolerate indentation before the prefix, then read the prefix.
        local probe = line:match("^%s*(.*)$")
        local prefix = probe:sub(1, 2)
        if prefix == "Q:" then
            mode = "Q"
            q[#q + 1] = trim(probe:sub(3))
        elseif prefix == "A:" then
            mode = "A"
            a[#a + 1] = trim(probe:sub(3))
        elseif mode then
            -- Continuation line, appended to the current section.
            if mode == "Q" then
                q[#q + 1] = trim(line)
            else
                a[#a + 1] = trim(line)
            end
        end
    end
    local question = trim(table.concat(q, "\n"))
    local answer = trim(table.concat(a, "\n"))
    if question == "" or answer == "" then
        return nil
    end
    return { question = question, answer = answer }
end

--[[
-- Parse flashcard file content into a list of cards.
-- Each card is  { question = string, answer = string }.
-- Blocks with only a question or only an answer are silently dropped.
--]]
function Parser.parse(content)
    local cards = {}
    for _, part in ipairs(splitBlocks(content)) do
        local block = trim(part)
        if block ~= "" then
            local card = parseBlock(block)
            if card then
                cards[#cards + 1] = card
            end
        end
    end
    return cards
end

return Parser