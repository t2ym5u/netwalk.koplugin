-- ---------------------------------------------------------------------------
-- NetwalkBoard — game state and logic for Net (Simon Tatham's "Net").
--
-- The solution is a spanning tree of pipes over the grid, powered from a
-- source tile in the middle. Every tile was rotated at random; the player
-- rotates them back. Tiles are 4-bit arm masks (N=1, E=2, S=4, W=8, see
-- solver.lua), so the state is just tiles[r][c] plus a lock flag per cell.
--
-- The win check never compares against the stored solution: any rotation of
-- the tiles that forms one loop-free network with no loose end wins. The
-- generator proves the solution unique anyway (see generate()), so in
-- practice the two agree; the stored one is only there for hints and for
-- "Show solution".
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack = require("undo_stack")
local Timer     = require("timer")
local Hint      = require("hint")
local Solver    = lrequire("solver")

local BIT, OPP, DR, DC = Solver.BIT, Solver.OPP, Solver.DR, Solver.DC
local hasArm = Solver.hasArm

local SIZES     = { 5, 7, 9, 11 }
local DEFAULT_N = 7

-- Deduction level that must crack a puzzle of each difficulty, and the level
-- that must NOT (so medium/hard really need the extra reasoning). See the
-- header of solver.lua for what each level knows.
--   easy    local rules only
--   medium  needs loop avoidance
--   hard    needs "a group must keep a way out" -- rare in random trees, so
--           the generator tries a while and then settles for medium-grade.
local LEVELS = {
    easy   = { solve = 0, beat = nil },
    medium = { solve = 1, beat = 0 },
    hard   = { solve = 2, beat = 1 },
}
local MAX_TRIES = 80

local NetwalkBoard = {}
NetwalkBoard.__index = NetwalkBoard

function NetwalkBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local b = setmetatable({
        n             = n,
        rows          = n,
        cols          = n,
        difficulty    = opts.difficulty or "easy",
        tiles         = {},   -- tiles[r][c]    = current arm mask
        solution      = {},   -- solution[r][c] = solved arm mask
        locked        = {},   -- locked[r][c]   = true when the player pinned it
        src_r         = math.floor((n + 1) / 2),
        src_c         = math.floor((n + 1) / 2),
        moves         = 0,
        hints_used    = 0,
        show_solution = false,
        selected      = nil,
        undo_stack    = UndoStack:new(),
        timer         = Timer:new(),
    }, self)
    return b
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

-- A random spanning tree grown outward from the source (randomised Prim:
-- each step adds one random edge from the tree to a cell outside it). This
-- gives the bushy, many-branched trees Net is known for. Returns flat masks.
local function randomTree(n, src)
    local nb = Solver.neighbours(n, n)
    local total = n * n
    local masks, intree, frontier = {}, { [src] = true }, {}
    for i = 1, total do masks[i] = 0 end
    local function addFrontier(i)
        for d = 1, 4 do
            local j = nb[i][d]
            if j and not intree[j] then frontier[#frontier + 1] = { i, d } end
        end
    end
    addFrontier(src)
    local count = 1
    while count < total do
        local k = math.random(#frontier)
        local e = frontier[k]
        frontier[k] = frontier[#frontier]
        frontier[#frontier] = nil
        local i, d = e[1], e[2]
        local j = nb[i][d]
        if not intree[j] then
            masks[i] = masks[i] + BIT[d]
            masks[j] = masks[j] + BIT[OPP[d]]
            intree[j] = true
            count = count + 1
            addFrontier(j)
        end
    end
    return masks
end

-- Does this tree's puzzle land in the band asked for? Solving by deduction
-- also proves the solution unique (every rule only removes rotations that
-- cannot be part of any solution), so a puzzle that passes is unique.
-- Solver.rate runs the levels one after the other on the same state, so a
-- tree too easy for Hard costs one level-1 solve instead of a level-2 solve
-- plus a level-1 one (same verdicts as before, about twice as fast).
local function fits(masks, n, band, strict)
    local level = Solver.rate(masks, n, n, band.solve)
    if not level then return false end
    if strict and band.beat and level <= band.beat then return false end
    return true
end

-- on_progress (optional) is called with a 0..1 fraction between tries.
function NetwalkBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    local n    = self.n
    local band = LEVELS[self.difficulty] or LEVELS.easy
    local src  = (self.src_r - 1) * n + self.src_c

    -- First pass: insist the puzzle needs the level it is rated at. The hard
    -- band is rare, so after MAX_TRIES accept anything one level easier that
    -- still needs more than local rules; last resort, any unique puzzle.
    local masks
    local function progress(k)
        if on_progress then on_progress(k / (2 * MAX_TRIES)) end
    end
    for k = 1, MAX_TRIES do
        progress(k)
        local t = randomTree(n, src)
        if fits(t, n, band, true) then masks = t; break end
    end
    if not masks and band.solve == 2 then
        for k = 1, MAX_TRIES do
            progress(MAX_TRIES + k)
            local t = randomTree(n, src)
            if fits(t, n, LEVELS.medium, true) then masks = t; break end
        end
    end
    while not masks do
        local t = randomTree(n, src)
        if fits(t, n, band, false) then masks = t end
    end

    self.tiles, self.solution, self.locked = {}, {}, {}
    for r = 1, n do
        self.tiles[r], self.solution[r], self.locked[r] = {}, {}, {}
        for c = 1, n do
            local m = masks[(r - 1) * n + c]
            self.solution[r][c] = m
            -- Scramble: a random quarter-turn count per tile.
            for _ = 1, math.random(0, 3) do m = Solver.rotateCW(m) end
            self.tiles[r][c] = m
            self.locked[r][c] = false
        end
    end
    -- Starting already solved would be a non-puzzle: turn one asymmetric
    -- tile (any non-cross tile has a rotation that differs).
    if self:isSolved() then
        local done = false
        for r = 1, n do
            for c = 1, n do
                local m = self.tiles[r][c]
                if not done and Solver.rotateCW(m) ~= m then
                    self.tiles[r][c] = Solver.rotateCW(m)
                    done = true
                end
            end
        end
    end

    self.moves         = 0
    self.hints_used    = 0
    self.show_solution = false
    self.selected      = nil
    self.undo_stack:clear()
    self.timer:reset()
    self.timer:start()
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

-- Rotate the tile at (r, c) a quarter turn (clockwise unless ccw). Locked
-- tiles and a finished board refuse. Returns true when the tile turned.
function NetwalkBoard:rotate(r, c, ccw)
    if self.show_solution or self:isSolved() then return false end
    if self.locked[r][c] then return false end
    local m = self.tiles[r][c]
    local turned = ccw and Solver.rotateCCW(m) or Solver.rotateCW(m)
    if turned == m then return false end   -- a cross looks the same every way
    self.undo_stack:push({ r = r, c = c, mask = m, locked = false })
    self.tiles[r][c] = turned
    self.moves = self.moves + 1
    self.selected = nil
    if not self.timer:isRunning() then self.timer:start() end
    if self:isSolved() then self.timer:stop() end
    return true
end

-- Lock marks are the player's notes ("this one is right"): they block
-- rotation and are undoable, but don't count as moves.
function NetwalkBoard:toggleLock(r, c)
    if self.show_solution or self:isSolved() then return false end
    self.undo_stack:push({ r = r, c = c, mask = self.tiles[r][c], locked = self.locked[r][c] })
    self.locked[r][c] = not self.locked[r][c]
    self.selected = nil
    return true
end

function NetwalkBoard:canUndo()
    return self.undo_stack:canUndo() and not self.show_solution and not self:isSolved()
end

function NetwalkBoard:undo()
    if not self:canUndo() then return false end
    local e = self.undo_stack:pop()
    if e.mask ~= self.tiles[e.r][e.c] and not e.hint then
        self.moves = math.max(0, self.moves - 1)
    end
    self.tiles[e.r][e.c]  = e.mask
    self.locked[e.r][e.c] = e.locked
    self.selected = nil
    return true
end

-- ---------------------------------------------------------------------------
-- Network state
-- ---------------------------------------------------------------------------

function NetwalkBoard:_flat(grid)
    local out, n = {}, self.n
    for r = 1, n do
        for c = 1, n do out[(r - 1) * n + c] = grid[r][c] end
    end
    return out
end

-- Every arm meets an arm, nothing points off the grid, and the pipes form
-- one tree over every tile.
function NetwalkBoard:isSolved()
    if not self.tiles[1] then return false end
    return Solver.isSolved(self:_flat(self.tiles), self.n, self.n)
end

-- Cells reached from the source through arms that meet: powered[r][c].
-- `grid` defaults to the current tiles.
function NetwalkBoard:getPowered(grid)
    grid = grid or self.tiles
    local n = self.n
    local powered = {}
    for r = 1, n do powered[r] = {} end
    local stack = { { self.src_r, self.src_c } }
    powered[self.src_r][self.src_c] = true
    local count = 1
    while #stack > 0 do
        local cell = table.remove(stack)
        local r, c = cell[1], cell[2]
        for d = 1, 4 do
            local nr, nc = r + DR[d], c + DC[d]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                    and not powered[nr][nc]
                    and hasArm(grid[r][c], d) and hasArm(grid[nr][nc], OPP[d]) then
                powered[nr][nc] = true
                count = count + 1
                stack[#stack + 1] = { nr, nc }
            end
        end
    end
    return powered, count
end

function NetwalkBoard:countPowered()
    local _, count = self:getPowered()
    return count
end

-- What the widget should draw: the solution while it is shown.
function NetwalkBoard:getDisplayTiles()
    return self.show_solution and self.solution or self.tiles
end

function NetwalkBoard:isShowingSolution()
    return self.show_solution
end

function NetwalkBoard:toggleSolution()
    self.show_solution = not self.show_solution
    self.selected = nil
end

function NetwalkBoard:setSelection(r, c)
    self.selected = { r = r, c = c }
end

-- ---------------------------------------------------------------------------
-- Hints
--
-- A tile counts as "answered" once the player has locked it, or once it
-- already sits the right way: the hint then points at a tile that is still
-- wrong, or at a locked tile that is wrong (a mistake, which it unlocks).
-- Masks are compared, not rotation counts, so a straight pipe turned 180°
-- is as right as the stored one.
-- ---------------------------------------------------------------------------

-- Set a tile to `mask` and lock it, as one undoable step (not a move).
function NetwalkBoard:_hintSet(r, c, mask)
    self.undo_stack:push({ r = r, c = c, mask = self.tiles[r][c],
                           locked = self.locked[r][c], hint = true })
    self.tiles[r][c]  = mask
    self.locked[r][c] = true
    if self:isSolved() then self.timer:stop() end
    return true
end

function NetwalkBoard:_hintUnlock(r, c)
    self.undo_stack:push({ r = r, c = c, mask = self.tiles[r][c],
                           locked = self.locked[r][c], hint = true })
    self.locked[r][c] = false
    return true
end

Hint.install(NetwalkBoard, {
    getUser = function(b, r, c)
        local m = b.tiles[r][c]
        if b.locked[r][c] or m == b.solution[r][c] then return m end
        return nil
    end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    setCell     = function(b, r, c, v) return b:_hintSet(r, c, v) end,
    clearCell   = function(b, r, c) return b:_hintUnlock(r, c) end,
})

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function NetwalkBoard:serialize()
    -- Timer:serialize stops the clock to bank the elapsed time; keep it
    -- running, since saving happens after every move.
    local timer = self.timer:serialize()
    if timer.was_running then self.timer:start() end
    local locked = {}
    for r = 1, self.n do
        for c = 1, self.n do
            locked[(r - 1) * self.n + c] = self.locked[r][c] and 1 or 0
        end
    end
    return {
        n          = self.n,
        difficulty = self.difficulty,
        tiles      = self:_flat(self.tiles),
        solution   = self:_flat(self.solution),
        locked     = locked,
        moves      = self.moves,
        hints_used = self.hints_used,
        timer      = timer,
        undo       = self.undo_stack:serialize(),
    }
end

function NetwalkBoard:load(data)
    if type(data) ~= "table" or type(data.tiles) ~= "table"
            or type(data.solution) ~= "table" or not data.n then
        return false
    end
    local n = data.n
    if #data.tiles ~= n * n or #data.solution ~= n * n then return false end
    self.n, self.rows, self.cols = n, n, n
    self.src_r = math.floor((n + 1) / 2)
    self.src_c = self.src_r
    self.difficulty = data.difficulty or self.difficulty
    self.tiles, self.solution, self.locked = {}, {}, {}
    for r = 1, n do
        self.tiles[r], self.solution[r], self.locked[r] = {}, {}, {}
        for c = 1, n do
            local i = (r - 1) * n + c
            self.tiles[r][c]    = data.tiles[i]
            self.solution[r][c] = data.solution[i]
            self.locked[r][c]   = (data.locked and data.locked[i] == 1) or false
        end
    end
    self.moves         = data.moves or 0
    self.hints_used    = data.hints_used or 0
    self.show_solution = false
    self.selected      = nil
    self.timer         = Timer:new()
    if data.timer then self.timer:load(data.timer) end
    self.undo_stack:load(data.undo)
    return true
end

NetwalkBoard.SIZES     = SIZES
NetwalkBoard.DEFAULT_N = DEFAULT_N
NetwalkBoard.LEVELS    = LEVELS
NetwalkBoard.randomTree = randomTree

return NetwalkBoard
