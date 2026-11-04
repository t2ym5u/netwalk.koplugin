local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local GenProgress        = require("gen_progress")
local NetwalkBoard       = lrequire("board")
local NetwalkBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = _([[
Net — Rules

The grid holds a network of pipes, but every tile has been turned at random. Turn the tiles back so that the whole network is connected.

Rules:
• Every pipe end must meet a pipe end on the neighbouring tile — no loose ends, and nothing may point off the grid.
• All tiles must form one single network, with no loops.
• Power flows from the source (the double square in the middle): connected tiles are drawn solid, the rest hollow. When every tile is solid and no end is loose, the puzzle is solved.

Tap a tile to turn it a quarter turn (clockwise by default; the menu switches the direction). Long-press a tile to lock it once you are sure of it: a locked tile is shaded and will not turn. Long-press again to unlock it.

Every puzzle has exactly one solution and can be solved by reasoning alone. Start at the edges and corners: a pipe can never point off the grid.
]])

local GAME_RULES_FR = [[
Net — Règles

La grille contient un réseau de tuyaux, mais chaque tuile a été tournée au hasard. Remettez les tuiles dans le bon sens pour que tout le réseau soit relié.

Règles :
• Chaque extrémité de tuyau doit rejoindre une extrémité sur la tuile voisine — aucune extrémité libre, et rien ne doit sortir de la grille.
• Toutes les tuiles doivent former un seul réseau, sans boucle.
• Le courant part de la source (le double carré au centre) : les tuiles reliées sont dessinées pleines, les autres creuses. Quand toutes les tuiles sont pleines et qu'aucune extrémité n'est libre, le puzzle est résolu.

Appuyez sur une tuile pour la tourner d'un quart de tour (dans le sens horaire par défaut ; le menu change le sens). Restez appuyé sur une tuile pour la verrouiller quand vous en êtes sûr : une tuile verrouillée est grisée et ne tourne plus. Restez appuyé à nouveau pour la déverrouiller.

Chaque puzzle a une seule solution et se résout par le raisonnement seul. Commencez par les bords et les coins : un tuyau ne peut jamais sortir de la grille.
]]

local NetwalkScreen = ScreenBase:extend{}

-- The unit is a tile's orientation, so the hint names it in those words
-- instead of the default "can be worked out / fill it in".
function NetwalkScreen:describeHintStep(step, level)
    if level == 1 then
        return step.kind == "mistake"
            and T(_("The tile at R%1C%2 is locked the wrong way. Tap Hint again to unlock it."), step.r, step.c)
            or  T(_("The tile at R%1C%2 can be worked out. Tap Hint again to turn and lock it."), step.r, step.c)
    end
    return step.kind == "mistake"
        and T(_("Unlocked R%1C%2."), step.r, step.c)
        or  T(_("Turned and locked R%1C%2."), step.r, step.c)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function NetwalkScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", NetwalkBoard.DEFAULT_N)
    self.board  = NetwalkBoard:new{ n = n }
    if not self.board:load(state) then
        self:_generate(self.plugin:getSetting("difficulty", "easy"))
    end
    ScreenBase.init(self)
end

-- Hard has to try many random networks before one needs the hardest
-- reasoning; on a slow e-reader the progress bar shows if that takes a while.
function NetwalkScreen:_generate(diff)
    GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
end

function NetwalkScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function NetwalkScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Net"), function()
        return {
            { text = _("New game"),                callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getSizeButtonText(),     callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(),     callback = function() self:openDifficultyMenu() end },
            { text = self:getRotationButtonText(), callback = function() self:toggleRotation() end },
            { text = self:getRevealButtonText(),   callback = function() self:toggleSolution() end },
            { text = _("Restart"),                 callback = function() self:onRestart() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Hint"), callback = function() self:onHint() end },
        { id = "undo_button", text = _("Undo"), callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    self:updateUndoButton()
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    local frame_pad   = Size.padding.large
    local frame_extra = 2 * (frame_pad + Size.border.window)
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = NetwalkBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold) self:onCellAction(r, c, is_hold) end,
    }
    local board_frame = FrameContainer:new{
        padding = frame_pad,
        margin  = 0,
        self.board_widget,
    }

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function NetwalkScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() then
        self:updateStatus(_("Solution is shown; editing is disabled."))
        return
    end
    local changed
    if is_hold then
        changed = self.board:toggleLock(r, c)
    else
        changed = self.board:rotate(r, c, self:isCounterClockwise())
    end
    if not changed then
        if not is_hold and self.board.locked[r][c] then
            self:updateStatus(_("This tile is locked. Long-press it to unlock."))
        end
        return
    end
    self.hint_cell = nil
    self.board_widget:refresh()
    self.plugin:saveState(self.board:serialize())
    self:updateUndoButton()
    if self.board:isSolved() then self:recordWin() end
    self:updateStatus()
end

function NetwalkScreen:isRoundOver()
    return self.board:isSolved()
end

-- Best time per size and difficulty, in seconds.
function NetwalkScreen:bestKey()
    return "best_time_" .. self.board.n .. "_" .. self.board.difficulty
end

function NetwalkScreen:recordWin()
    if self.board:getHintsUsed() > 0 then return end
    local secs = math.floor(self.board.timer:getElapsed())
    local best = self.plugin:getSetting(self:bestKey())
    if not best or secs < best then
        self.plugin:saveSetting(self:bestKey(), secs)
    end
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function NetwalkScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", NetwalkBoard.DEFAULT_N)
    self.board = NetwalkBoard:new{ n = n }
    self:_generate(diff)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Back to the scrambled start: undo everything, hints included.
function NetwalkScreen:onRestart()
    if self.board:isShowingSolution() then self.board:toggleSolution() end
    while self.board.undo_stack:canUndo() do
        local e = self.board.undo_stack:pop()
        self.board.tiles[e.r][e.c]  = e.mask
        self.board.locked[e.r][e.c] = e.locked
    end
    self.board.moves = 0
    self.board.selected = nil
    self.hint_cell = nil
    self.board.timer:start()
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    self:updateUndoButton()
    self:updateStatus()
end

function NetwalkScreen:onUndo()
    if not self.board:undo() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    self:updateUndoButton()
    self:updateStatus(_("Last move undone."))
end

function NetwalkScreen:onHint()
    ScreenBase.onHint(self)
    self:updateUndoButton()
    if self.board:isSolved() then self:refreshActionBar() end
end

function NetwalkScreen:toggleSolution()
    self.board:toggleSolution()
    self.hint_cell = nil
    self.board_widget:refresh()
    self:updateUndoButton()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function NetwalkScreen:isCounterClockwise()
    return self.plugin:getSetting("rotate_ccw", false) and true or false
end

function NetwalkScreen:toggleRotation()
    self.plugin:saveSetting("rotate_ccw", not self:isCounterClockwise())
    self:updateStatus(T(_("Tap now turns tiles %1."),
        self:isCounterClockwise() and _("counter-clockwise") or _("clockwise")))
end

function NetwalkScreen:openSizeMenu()
    local sizes = {}
    for _, n in ipairs(NetwalkBoard.SIZES) do
        sizes[#sizes + 1] = { id = n, text = n .. "\xC3\x97" .. n }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.board.n,
        parent    = self,
        on_select = function(n)
            self.plugin:saveSetting("grid_n", n)
            self:onNewGame()
        end,
    }
end

function NetwalkScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status / button text
-- ---------------------------------------------------------------------------

function NetwalkScreen:getSizeButtonText()
    return T(_("Size: %1"), T("%1×%1", self.board.n))
end

function NetwalkScreen:getDiffLabel()
    local diff = self.board.difficulty
    return MenuHelper.DIFFICULTY_LABELS[diff] or diff
end

function NetwalkScreen:getDiffButtonText()
    return T(_("Difficulty: %1"), self:getDiffLabel())
end

function NetwalkScreen:getRotationButtonText()
    return T(_("Rotation: %1"),
        self:isCounterClockwise() and _("counter-clockwise") or _("clockwise"))
end

function NetwalkScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

local function formatSecs(secs)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

function NetwalkScreen:updateStatus(msg)
    local status
    local board = self.board
    if msg then
        status = msg
    elseif board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif board:isSolved() then
        local secs = math.floor(board.timer:getElapsed())
        local best = self.plugin:getSetting(self:bestKey())
        status = self:joinStatus(
            T(_("Network connected in %1 moves!"), board.moves),
            T(_("Time: %1"), formatSecs(secs)),
            best and T(_("Best: %1"), formatSecs(best)))
    else
        status = self:joinStatus(
            T("%1×%1", board.n),
            self:getDiffLabel(),
            T(_("Powered: %1/%2"), board:countPowered(), board.n * board.n),
            T(_("Moves: %1"), board.moves))
    end
    ScreenBase.updateStatus(self, status)
    self:refreshActionBar()
end

function NetwalkScreen:updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return NetwalkScreen
