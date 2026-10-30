local Blitbuffer = require("ffi/blitbuffer")
local Size       = require("ui/size")
local common     = require("grid_widget_base")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Solver = lrequire("solver")

local GridWidgetBase = common.GridWidgetBase
local drawLine       = common.drawLine
local hasArm         = Solver.hasArm

local C_BG     = Blitbuffer.COLOR_WHITE
local C_INK    = Blitbuffer.COLOR_BLACK
local C_GRID   = Blitbuffer.COLOR_GRAY_9
local C_LOCKED = Blitbuffer.COLOR_GRAY_D

-- ---------------------------------------------------------------------------
-- NetwalkBoardWidget — draws the pipes.
--
-- E-ink has no colour to show "this part has power", so shape does it:
-- powered pipes are solid black, unpowered ones are hollow (a black outline
-- around white). Dead ends carry a terminal box, filled once powered; the
-- source is a bold double square. Locked tiles get a light grey backing.
-- ---------------------------------------------------------------------------

local NetwalkBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function NetwalkBoardWidget:init()
    self.cols = self.board and self.board.n or 7
    self.rows = self.cols
    GridWidgetBase.init(self)
end

function NetwalkBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function NetwalkBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

-- One cell's pipes. (cx, cy) is the cell centre, h the half-cell, w the pipe
-- width. Hollow pipes are drawn as a black body, then a white core inset by
-- `edge` that runs to the cell border so it meets the neighbour's core.
local function paintArms(bb, cx, cy, h, w, mask, color)
    local hw = math.floor(w / 2)
    for d = 1, 4 do
        if hasArm(mask, d) then
            if d == 1 then bb:paintRect(cx - hw, cy - h, w, h + hw, color)
            elseif d == 2 then bb:paintRect(cx - hw, cy - hw, h + hw + 1, w, color)
            elseif d == 3 then bb:paintRect(cx - hw, cy - hw, w, h + hw + 1, color)
            else bb:paintRect(cx - h, cy - hw, h + hw, w, color) end
        end
    end
end

function NetwalkBoardWidget:paintTo(bb, x, y)
    local rect = self.paint_rect
    rect.x, rect.y = x, y
    local board = self.board
    local n     = board.n
    local cell  = self.cell_w
    local show  = board:isShowingSolution()
    local tiles = board:getDisplayTiles()
    local powered = board:getPowered(tiles)

    bb:paintRect(x, y, rect.w, rect.h, C_BG)

    local w    = math.max(5, math.floor(cell * 0.24))
    local edge = math.max(2, math.floor(w / 4))
    local term = math.max(w + 4, math.floor(cell * 0.46))

    for r = 1, n do
        for c = 1, n do
            local x0 = x + math.floor((c - 1) * cell)
            local y0 = y + math.floor((r - 1) * cell)
            local x1 = x + math.floor(c * cell)
            local y1 = y + math.floor(r * cell)
            local h  = math.floor((x1 - x0) / 2)
            local cx = x0 + h
            local cy = y0 + math.floor((y1 - y0) / 2)
            local mask = tiles[r][c]
            local lit  = powered[r][c]

            if board.locked[r][c] and not show then
                bb:paintRect(x0, y0, x1 - x0, y1 - y0, C_LOCKED)
            end

            -- Pipes: black body, then (unpowered) a white core.
            paintArms(bb, cx, cy, h, w, mask, C_INK)
            bb:paintRect(cx - math.floor(w / 2), cy - math.floor(w / 2), w, w, C_INK)
            if not lit then
                local core = w - 2 * edge
                if core > 0 then
                    paintArms(bb, cx, cy, h, core, mask, C_BG)
                    bb:paintRect(cx - math.floor(core / 2), cy - math.floor(core / 2), core, core, C_BG)
                end
            end

            local is_src = r == board.src_r and c == board.src_c
            if is_src then
                -- Source: a bold square with a white ring inside.
                local s = math.floor(cell * 0.56)
                bb:paintRect(cx - math.floor(s / 2), cy - math.floor(s / 2), s, s, C_INK)
                local s2 = s - 4 * edge
                bb:paintRect(cx - math.floor(s2 / 2), cy - math.floor(s2 / 2), s2, s2, C_BG)
                local s3 = s2 - 2 * edge
                bb:paintRect(cx - math.floor(s3 / 2), cy - math.floor(s3 / 2), s3, s3, C_INK)
            elseif Solver.armCount(mask) == 1 then
                -- Terminal: a box at the dead end, filled once powered.
                bb:paintRect(cx - math.floor(term / 2), cy - math.floor(term / 2), term, term, C_INK)
                if not lit then
                    local t2 = term - 2 * edge
                    bb:paintRect(cx - math.floor(t2 / 2), cy - math.floor(t2 / 2), t2, t2, C_BG)
                end
            end
        end
    end

    -- Grid lines: thin and grey, so they never read as pipes.
    local thin = Size.line.thin or 1
    for i = 0, n do
        local pos = math.min(math.floor(i * cell), rect.w - thin)
        drawLine(bb, x + pos, y, thin, rect.h, C_GRID)
        drawLine(bb, x, y + pos, rect.w, thin, C_GRID)
    end

    -- Hint target: a heavy frame around the cell.
    local sel = board.selected
    if sel and not show then
        local x0 = x + math.floor((sel.c - 1) * cell)
        local y0 = y + math.floor((sel.r - 1) * cell)
        local s  = math.ceil(cell)
        local t  = math.max(3, math.floor(cell * 0.08))
        drawLine(bb, x0, y0, s, t, C_INK)
        drawLine(bb, x0, y0 + s - t, s, t, C_INK)
        drawLine(bb, x0, y0, t, s, C_INK)
        drawLine(bb, x0 + s - t, y0, t, s, C_INK)
    end
end

return NetwalkBoardWidget
