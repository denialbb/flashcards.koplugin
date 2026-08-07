--[[--
Flashcards for KOReader. Quiz yourself on the syncnotes-based flashcards.md
corpus, on-device, with an e-ink friendly touch UI.

Flow mirrors the desktop ~/.local/bin/quiz.py tool: pick a theme (or all
themes combined), pick a deck length, self-score each card (reveal → "got it /
missed"), then a summary with an optional review of the missed cards. The
"missed" set is persisted so it can be re-reviewed in a later session.

Pure logic lives in parser.lua and quiz.lua; this file is a thin adapter onto
KOReader widgets. Parser/quiz are unit-tested and are also driven by the local
CLI (tools/flashcards-cli.lua), so the exact same code can be run off-device.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local ConfirmBox        = require("ui/widget/confirmbox")
local InputDialog       = require("ui/widget/inputdialog")
local Menu              = require("ui/widget/menu")
local ScrollTextWidget  = require("ui/widget/scrolltextwidget")
local TextWidget        = require("ui/widget/textwidget")
local TextBoxWidget     = require("ui/widget/textboxwidget")
local ButtonTable       = require("ui/widget/buttontable")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local FrameContainer    = require("ui/widget/container/framecontainer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local InputContainer    = require("ui/widget/container/inputcontainer")
local DataStorage       = require("datastorage")
local LuaSettings       = require("luasettings")
local Font              = require("ui/font")
local Size              = require("ui/size")
local Geom              = require("ui/geometry")
local Screen            = require("device").screen
local logger            = require("logger")
local lfs               = require("libs/libkoreader-lfs")
local Parser            = require("parser")
local Quiz              = require("quiz")
local Discovery         = require("discovery")
local _                 = require("gettext")
local T                 = require("ffi/util").template
local Blitbuffer        = require("ffi/blitbuffer")

--[[--
Reusable full-screen dialog: a header (title + subtitle), a body widget and a
button row. The physical Back key routes through onClose; the explicit buttons
call UIManager:close(self) directly, which raises a distinct CloseWidget event
and never re-enters onClose — so there is no double-prompt risk.
]]
local FlashcardDialog = InputContainer:extend{
    name = "flashcards_dialog",
    title = "",
    subtitle = "",
    body = nil,     -- any single widget (a ScrollTextWidget is typical)
    buttons = nil,  -- a ButtonTable
    on_back = nil,  -- optional callback run on the physical Back key only
    on_forward = nil,
    on_backward = nil,
    covers_fullscreen = true,
    covers_footer = true,
}

function FlashcardDialog:init()
    local Device = require("device")
    self.covers_fullscreen = true
    self.key_events = {
        Close = { { Device.input.group.Back } },
        NextPage = { { Device.input.group.PgFwd } },
        PrevPage = { { Device.input.group.PgBack } },
    }

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(12)
    local content_w = sw - 2 * margin

    local vgroup = VerticalGroup:new{}

    local header = VerticalGroup:new{}
    table.insert(header, TextWidget:new{
        text = self.title,
        face = Font:getFace("ffont", 22),
        bold = true,
    })
    if self.subtitle ~= "" then
        table.insert(header, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(header, TextWidget:new{
            text = self.subtitle,
            face = Font:getFace("smallffont", 14),
            max_width = content_w,
        })
    end

    table.insert(vgroup, header)
    table.insert(vgroup, VerticalSpan:new{ width = Size.span.vertical_default })
    if self.body then table.insert(vgroup, self.body) end
    table.insert(vgroup, VerticalSpan:new{ width = Size.span.vertical_default })
    if self.buttons then table.insert(vgroup, self.buttons) end

    self[1] = FrameContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        padding = margin,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }
    self.dimen = self[1].dimen
end

--[[
Physical Back: if the dialog has an on_back action (e.g. quit-with-confirm),
run it and keep the dialog open beneath the resulting confirmation; the
confirm's Cancel path leaves the card intact. Otherwise just close.
]]
function FlashcardDialog:onClose()
    if self.on_back then
        self.on_back()
        -- stay open: on_back is expected to show a dialog over us
    else
        UIManager:close(self)
    end
    return true
end

function FlashcardDialog:onNextPage()
    if self.on_forward then
        self.on_forward()
    end
    return true
end

function FlashcardDialog:onPrevPage()
    if self.on_backward then
        self.on_backward()
    end
    return true
end

local Flashcards = WidgetContainer:extend{
    name = "flashcards",
    is_doc_only = false,
}

function Flashcards:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/flashcards.lua"
    self.settings = LuaSettings:open(self.settings_file)
    if not self.settings:readSetting("root") then
        self.settings:saveSetting("root", DataStorage:getDataDir() .. "/notes")
        self.settings:flush()
    end
    self.debug_log_path = DataStorage:getSettingsDir() .. "/flashcards.log"
    self.current_dialog = nil
    self:log("info", "Flashcards plugin initialized; settings %s; debug log %s",
        self.settings_file, self.debug_log_path)
    self.ui.menu:registerToMainMenu(self)
end

--- Write a timestamped line to KOReader's logger (ends up in crash.log) AND to
--- our own file at settings/flashcards.log, so history is available offline.
function Flashcards:log(level, msg, ...)
    local line, n = msg, select("#", ...)
    if n > 0 then
        local ok, res = pcall(string.format, msg, ...)
        if ok then line = res end
    end
    if type(line) ~= "string" then line = tostring(line) end
    local full = string.format("[flashcards] %s", line)
    pcall(function()
        local fn = logger[level] or logger.info
        if type(fn) == "function" then
            fn(full)
        end
    end)
    pcall(function()
        local log_h = io.open(self.debug_log_path, "a")
        if log_h then
            log_h:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. full .. "\n")
            log_h:close()
        end
    end)
end

--- Wrap a menu handler so an thrown error is caught, logged, and shown on
--- screen. KOReader swallows menu-callback errors silently, which is why the
--- plugin originally looked like "nothing happened".
function Flashcards:withFeedback(cb)
    return function(...)
        local ok, err = pcall(cb, ...)
        if not ok then
            local msg = tostring(err)
            self:log("err", "handler error: %s\n%s", msg, debug and debug.traceback() or "")
            UIManager:show(InfoMessage:new{
                text = T(_("Flashcards error:\n\n%1"), msg),
                timeout = 12,
            })
        end
    end
end

function Flashcards:addToMainMenu(menu_items)
    menu_items.flashcards = {
        text = _("Flashcards"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Start Quiz"),
                help_text = _("Choose a theme (or all themes), then self-score each card. Missed cards are saved for review."),
                callback = self:withFeedback(function() self:onStartQuiz() end),
            },
            {
                text = _("Review Missed Cards"),
                help_text = _("Re-quiz the cards you missed in your last finished quiz."),
                callback = self:withFeedback(function() self:onReviewMissed() end),
            },
            {
                text = _("Set Notes Folder"),
                help_text = _("The folder searched recursively for flashcards.md files."),
                callback = self:withFeedback(function() self:onSetNotesFolder() end),
            },
            {
                text = _("Clear Quiz History"),
                help_text = _("Forget the saved missed-card set from your last quiz."),
                callback = self:withFeedback(function() self:onClearHistory() end),
            },
        },
    }
end

--- The notes root to scan for flashcards.md, from our own settings.
function Flashcards:getRoot()
    return self.settings:readSetting("root") or (DataStorage:getDataDir() .. "/notes")
end

function Flashcards:showMenu(title, items)
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        cancel_callback = function()
            UIManager:close(menu)
            UIManager:setDirty(nil, "full")
        end,
    }
    UIManager:show(menu)
end

--[[
Recursively find flashcards.md files under a root. Returns { theme = path }.
A "theme" is the basename of the directory holding the file, matching the
desktop tool. Dot-directories are skipped. Duplicated theme names keep the
last (deepest) file, mirroring the desktop tool's dict overwrite.
--]]
function Flashcards:findThemeFiles(root)
    return Discovery.find(root, lfs, function(msg)
        self:log("warn", "%s", msg)
    end)
end

--- { theme = { path =, cards = {cards} }, ... } for every theme with cards.
function Flashcards:loadThemes()
    local themes = {}
    for theme, path in pairs(self:findThemeFiles(self:getRoot())) do
        self:log("debug", "parsing %q (theme %s)", path, theme)
        local f = io.open(path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            local cards = Parser.parse(content)
            if #cards > 0 then
                themes[theme] = { path = path, cards = cards }
            else
                self:log("warn", "theme %s: no parseable cards, skipped", theme)
            end
        else
            self:log("warn", "cannot open file: %s", path)
        end
    end
    return themes
end

function Flashcards:onStartQuiz()
    local root = self:getRoot()
    if not lfs.attributes(root) then
        self:log("warn", "notes folder does not exist: %q", root)
        UIManager:show(InfoMessage:new{
            text = T(_("Notes folder not found:\n\n%1\n\nUse \"Set Notes Folder\" to pick a folder containing flashcards.md files."), root),
            timeout = 10,
        })
        return
    end

    self.themes = self:loadThemes()
    if not self.themes or next(self.themes) == nil then
        self:log("warn", "no theme found under %q", root)
        UIManager:show(InfoMessage:new{
            text = T(_("No flashcards.md files found under:\n\n%1\n\nPut flashcards.md files here (one theme per folder), or pick another folder via \"Set Notes Folder\"."), root),
            timeout = 10,
        })
        return
    end

    local items = {}
    local total_cards = 0
    for name, t in pairs(self.themes) do
        total_cards = total_cards + #t.cards
    end
    table.insert(items, {
        text = _("All Themes Combined"),
        mandatory = T(_("%1 cards"), total_cards),
        callback = function() self:onPickTheme(nil) end,
    })
    local names = {}
    for name in pairs(self.themes) do names[#names + 1] = name end
    table.sort(names)
    self:log("info", "found %d theme(s): %s", #names, table.concat(names, ", "))
    for i, name in ipairs(names) do
        local t = self.themes[name]
        table.insert(items, {
            text = name:gsub("_", " "),
            mandatory = T(_("%1 cards"), #t.cards),
            callback = function() self:onPickTheme(name) end,
        })
    end
    self:showMenu(_("Choose a theme"), items)
end

-- Collect the selected deck, then offer a deck length.
function Flashcards:onPickTheme(theme_name)
    local cards = {}
    if theme_name then
        cards = self.themes[theme_name].cards
    else
        local names = {}
        for name in pairs(self.themes) do names[#names + 1] = name end
        table.sort(names)
        for i, name in ipairs(names) do
            for j, c in ipairs(self.themes[name].cards) do
                cards[#cards + 1] = c
            end
        end
    end
    local total = #cards
    self.pending_cards = cards
    self.pending_label = theme_name or _("All Themes")

    local items = {
        {
            text = T(_("All (%1 cards)"), total),
            callback = function() self:startQuiz(total) end,
        },
    }
    for i, n in ipairs({ 10, 25, 50 }) do
        if n <= total then
            table.insert(items, {
                text = T(_("%1 cards"), n),
                callback = function() self:startQuiz(n) end,
            })
        end
    end
    self:showMenu(T(_("Quiz length (%1 cards available)"), total), items)
end

--- Build a shuffled Quiz over the chosen deck and begin.
function Flashcards:startQuiz(count)
    local cards = self.pending_cards
    if not cards then return end
    local deck = {}
    local n = math.min(count or #cards, #cards)
    for i = 1, n do deck[i] = cards[i] end
    self.pending_cards = nil
    self:runQuiz(Quiz.new{ cards = deck, theme = self.pending_label, shuffle = true })
end

function Flashcards:runQuiz(quiz)
    self.quiz = quiz
    self:showCard()
end

-- Show the current card (question, answer hidden). Ends the quiz when done.
function Flashcards:showCard()
    if not self.quiz then return end
    local card = self.quiz:current()
    if not card then
        self:finishQuiz()
        return
    end
    local dialog = self:buildCardDialog(self.quiz, card, false)
    self.current_dialog = dialog
    UIManager:show(dialog)
    UIManager:setDirty(nil, "full")
end

function Flashcards:showRevealed()
    local card = self.quiz and self.quiz:current()
    if not card then self:finishQuiz() return end
    self.quiz:reveal()
    local dialog = self:buildCardDialog(self.quiz, card, true)
    self.current_dialog = dialog
    UIManager:show(dialog)
    UIManager:setDirty(nil, "full")
end

function Flashcards:markCard(correct)
    if not self.quiz then return end
    self.quiz:mark(correct)
    self:showCard()
end

--- A labeled content block (question or answer).
local function contentBlock(text, face, w, h)
    return ScrollTextWidget:new{
        text = text,
        face = face,
        width = w,
        height = h,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

local BoldScrollTextWidget = ScrollTextWidget:extend{}
function BoldScrollTextWidget:init()
    ScrollTextWidget.init(self)
    self.text_widget = TextBoxWidget:new{
        text = self.text,
        face = self.face,
        width = self.width,
        height = self.height,
        fgcolor = self.fgcolor,
        bold = true,
    }
end

--- An easy-to-spot placeholder for the hidden answer.
local function hiddenBlock(content_w, a_h, text)
    return FrameContainer:new{
        dimen = Geom:new{ w = content_w, h = a_h },
        bordersize = 1,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = a_h },
            TextWidget:new{
                text = text,
                face = Font:getFace("ffont", 16),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
    }
end

--- Build the card widget; `revealed` shows the answer and the scoring buttons.
function Flashcards:buildCardDialog(quiz, card, revealed)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(12)
    local content_w = sw - 2 * margin
    local q_h = math.floor(sh * 0.36)
    local a_h = math.floor(sh * 0.22)

    local body = VerticalGroup:new{
        TextWidget:new{ text = _("Question"), face = Font:getFace("smallffont", 14), bold = true },
        BoldScrollTextWidget:new{
            text = card.question,
            face = Font:getFace("ffont", 18),
            width = content_w,
            height = q_h,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = Size.span.vertical_default },
        TextWidget:new{ text = _("Answer"), face = Font:getFace("smallffont", 14), bold = true },
        revealed and contentBlock(card.answer, Font:getFace("ffont", 16), content_w, a_h)
            or hiddenBlock(content_w, a_h, _("Answer hidden — tap \"Reveal Answer\" below.")),
    }

    local dialog
    local buttons
    local on_forward, on_backward
    if revealed then
        on_forward = function()
            UIManager:close(dialog)
            self:markCard(true)
        end
        on_backward = function()
            UIManager:close(dialog)
            self:markCard(false)
        end
        buttons = ButtonTable:new{
            width = content_w,
            buttons = {
                {
                    {
                        text = _("Got it"),
                        id = "correct",
                        callback = function()
                            UIManager:close(dialog)
                            self:markCard(true)
                        end,
                    },
                    {
                        text = _("Missed"),
                        id = "missed",
                        callback = function()
                            UIManager:close(dialog)
                            self:markCard(false)
                        end,
                    },
                },
                {
                    {
                        text = _("Quit"),
                        id = "quit",
                        callback = function()
                            UIManager:close(dialog)
                            self:confirmQuit()
                        end,
                    },
                },
            },
        }
    else
        on_forward = function()
            UIManager:close(dialog)
            self:showRevealed()
        end
        on_backward = function()
            UIManager:close(dialog)
            self:markCard(false)
        end
        buttons = ButtonTable:new{
            width = content_w,
            buttons = {
                {
                    {
                        text = _("Reveal Answer"),
                        id = "reveal",
                        callback = function()
                            UIManager:close(dialog)
                            self:showRevealed()
                        end,
                    },
                },
                {
                    {
                        text = _("Quit"),
                        id = "quit",
                        callback = function()
                            UIManager:close(dialog)
                            self:confirmQuit()
                        end,
                    },
                },
            },
        }
    end

    dialog = FlashcardDialog:new{
        title = T(_("Card %1/%2"), quiz.index + 1, quiz:total()),
        subtitle = quiz.theme,
        body = body,
        buttons = buttons,
        on_back = function() self:confirmQuit() end,
        on_forward = on_forward,
        on_backward = on_backward,
    }
    return dialog
end

--- Confirm-and-quit mid-quiz. On confirm, closes the card and finishes.
function Flashcards:confirmQuit()
    local quiz = self.quiz
    if not quiz then return end
    local s = quiz:summary()
    UIManager:show(ConfirmBox:new{
        text = T(_("Quit the quiz?\n\nAnswered: %1/%2\nCorrect: %3"),
            s.answered, s.total, s.score),
        ok_text = _("Quit"),
        ok_callback = function()
            if self.current_dialog then
                UIManager:close(self.current_dialog)
            end
            self.current_dialog = nil
            quiz.quit = true
            self:finishQuiz()
        end,
    })
end

--- Persist the result (so missed cards can be reviewed later) and show the
--- summary screen.
function Flashcards:finishQuiz()
    local quiz = self.quiz
    if not quiz then return end
    self.quiz = nil
    self.current_dialog = nil

    local s = quiz:summary()
    if s.answered == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No questions were answered."),
            timeout = 4,
        })
        return
    end

    self.settings:saveSetting("session", {
        theme = quiz.theme,
        score = s.score,
        answered = s.answered,
        missed = s.missed,
    })
    self.settings:flush()

    local text = T(_("Quiz finished.\n\nScore: %1/%2 (%3%%)\nMissed: %4"),
        s.score, s.answered, s.percent, s.missed_count)

    local dialog
    local buttons_rows = {}
    if s.missed_count > 0 then
        table.insert(buttons_rows, {
            {
                text = T(_("Review Missed (%1)"), s.missed_count),
                id = "review",
                callback = function()
                    UIManager:close(dialog)
                    self:runQuiz(Quiz.fromMissed(quiz))
                    UIManager:setDirty(nil, "full")
                end,
            },
        })
    end
    table.insert(buttons_rows, {  -- second row
        {
            text = _("Done"),
            id = "done",
            callback = function()
                UIManager:close(dialog)
                self:onStartQuiz()
                UIManager:setDirty(nil, "full")
            end,
        },
    })

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(12)
    local content_w = sw - 2 * margin
    dialog = FlashcardDialog:new{
        title = _("Quiz Summary"),
        body = VerticalGroup:new{
            contentBlock(text, Font:getFace("ffont", 18), content_w, math.floor(sh * 0.4)),
            VerticalSpan:new{ width = Size.span.vertical_default },
        },
        buttons = ButtonTable:new{
            width = content_w,
            buttons = buttons_rows,
        },
    }
    self.current_dialog = dialog
    UIManager:show(dialog)
    UIManager:setDirty(nil, "full")
end

--- Re-quiz the cards missed in the last finished quiz.
function Flashcards:onReviewMissed()
    local session = self.settings:readSetting("session")
    if not session or not session.missed or #session.missed == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No missed cards saved yet.\nFinish a quiz first."),
            timeout = 5,
        })
        return
    end
    self:runQuiz(Quiz.new{
        cards = session.missed,
        theme = T(_("Missed: %1"), session.theme or _("last quiz")),
        shuffle = true,
    })
end

function Flashcards:onClearHistory()
    UIManager:show(ConfirmBox:new{
        text = _("Clear the saved quiz history (missed cards)?"),
        ok_text = _("Clear"),
        ok_callback = function()
            self.settings:delSetting("session")
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = _("Quiz history cleared."),
                timeout = 2,
            })
        end,
    })
end

function Flashcards:onSetNotesFolder()
    local dialog
    dialog = InputDialog:new{
        title = _("Notes Folder"),
        input = self:getRoot(),
        description = _("Folder searched recursively for flashcards.md files."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if text and text ~= "" then
                            self.settings:saveSetting("root", text)
                            self.settings:flush()
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Notes folder set to:\n%1"), text),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Flashcards