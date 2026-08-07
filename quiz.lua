--[[--
Flashcard quiz engine. Pure Lua, no KOReader dependencies.

A small state machine over a shuffled deck of cards that tracks score and
misses, so the widget layer (KOReader) and the local CLI driver share exactly
one implementation of "how a quiz behaves".
]]

local Quiz = {}

local function shuffle(t, seed)
    if seed then
        math.randomseed(seed)
    end
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

--[[
-- Quiz.new{ cards = { {question=, answer=}, ... }, theme = string, shuffle = bool, seed = number|nil }
-- Cards are copied, then optionally shuffled (Fisher-Yates). Pass a fixed
-- `seed` for reproducible shuffles in tests and the CLI.
--]]
function Quiz.new(opts)
    local cards = {}
    for _, c in ipairs(opts.cards or {}) do
        cards[#cards + 1] = { question = c.question, answer = c.answer }
    end
    if opts.shuffle ~= false then
        shuffle(cards, opts.seed)
    end
    return setmetatable({
        cards = cards,
        index = 0,          -- answered so far; the next card is cards[index + 1]
        revealed = false,
        score = 0,          -- judged correct so far
        missed = {},        -- cards judged wrong, in order
        quit = false,
        theme = opts.theme or "",
    }, { __index = Quiz })
end

function Quiz:total()
    return #self.cards
end

-- The card currently on screen, or nil when the quiz is finished.
function Quiz:current()
    return self.cards[self.index + 1]
end

-- Reveal the answer of the current card. No-op if already revealed.
function Quiz:reveal()
    if self.revealed or not self:current() then
        return false
    end
    self.revealed = true
    return true
end

--[[
Record the user's self-judgement for the current card ("did you get it
right?") and advance to the next one. Wrong cards are kept in `missed` so
they can be reviewed afterwards. Returns the next card, or nil when done.
]]
function Quiz:mark(correct)
    local card = self:current()
    if not card then
        return nil
    end
    self.revealed = false
    self.index = self.index + 1
    if correct then
        self.score = self.score + 1
    else
        self.missed[#self.missed + 1] = card
    end
    return self:current()
end

-- True when every card has been judged or the quiz was quit early.
function Quiz:done()
    return self.index >= #self.cards or self.quit
end

--[[
Snapshot of results so far. Valid at any point; the summary screen uses it
when the quiz is done (or quit early).
  { score, answered, total, percent, missed, missed_count }
--]]
function Quiz:summary()
    local answered = self.index
    local percent = answered > 0 and math.floor(self.score / answered * 100 + 0.5) or 0
    return {
        score = self.score,
        answered = answered,
        total = #self.cards,
        percent = percent,
        missed = self.missed,
        missed_count = #self.missed,
    }
end

-- A fresh shuffled quiz over the missed cards of a previous one.
function Quiz.fromMissed(prev)
    return Quiz.new{ cards = prev.missed, theme = prev.theme, shuffle = true }
end

return Quiz