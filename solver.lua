-- ---------------------------------------------------------------------------
-- NetwalkSolver — deduction + backtracking over tile orientations.
--
-- A tile is a 4-bit mask of the arms it has: N=1, E=2, S=4, W=8. The player
-- can only rotate tiles, so each cell's unknown is which rotation of its
-- shape it ends up in. The solver keeps, per cell, the list of rotations
-- still possible (a straight pipe has 2 distinct ones, a cross only 1) and
-- narrows them with three levels of deduction, each including the one below:
--
--   level 0  local: an arm can't point off the grid, and the arm on one side
--            of an edge must agree with its neighbour's.
--   level 1  loops: two cells already joined by placed pipes can't be
--            joined again.
--   level 2  ways out: a group of joined cells that is not the whole grid
--            must keep at least one way out. With one way out left, that
--            way is forced; an edge that would merge two groups into one
--            closed group (two dead ends facing each other, typically) is
--            forbidden.
--
-- The generator rates puzzles by the lowest level that cracks them.
-- countSolutions adds branching on top of level 2 and is what the tests use
-- to confirm, independently, that a puzzle has exactly one answer.
--
-- Pure Lua arithmetic on purpose (no `bit` module): this file also runs under
-- the test suite's plain Lua.
-- ---------------------------------------------------------------------------

local Solver = {}

local BIT = { 1, 2, 4, 8 }           -- N, E, S, W
local OPP = { 3, 4, 1, 2 }
local DR  = { -1, 0, 1, 0 }
local DC  = { 0, 1, 0, -1 }

-- HAS[mask + 1][d] = true when the mask has an arm in direction d.
local HAS = {}
for m = 0, 15 do
    HAS[m + 1] = {}
    for d = 1, 4 do
        HAS[m + 1][d] = math.floor(m / BIT[d]) % 2 == 1
    end
end

local function hasArm(mask, d) return HAS[mask + 1][d] end

-- Rotating clockwise moves every arm one step round: N->E, E->S, S->W, W->N.
local function rotateCW(mask)
    return (mask * 2) % 16 + math.floor(mask / 8)
end

local function rotateCCW(mask)
    return math.floor(mask / 2) + (mask % 2) * 8
end

-- The distinct orientations of a shape, in clockwise order from `mask`.
local function rotations(mask)
    local out, seen, m = {}, {}, mask
    for _ = 1, 4 do
        if not seen[m] then
            seen[m] = true
            out[#out + 1] = m
        end
        m = rotateCW(m)
    end
    return out
end

local function armCount(mask)
    local n = 0
    for d = 1, 4 do if hasArm(mask, d) then n = n + 1 end end
    return n
end

Solver.BIT       = BIT
Solver.OPP       = OPP
Solver.DR        = DR
Solver.DC        = DC
Solver.hasArm    = hasArm
Solver.rotateCW  = rotateCW
Solver.rotateCCW = rotateCCW
Solver.rotations = rotations
Solver.armCount  = armCount

-- ---------------------------------------------------------------------------
-- Grid geometry. Cells are numbered 1..rows*cols in reading order;
-- nb[i][d] is the neighbour of cell i in direction d, or false off the grid.
-- ---------------------------------------------------------------------------

local function neighbours(rows, cols)
    local nb = {}
    for r = 1, rows do
        for c = 1, cols do
            local i = (r - 1) * cols + c
            nb[i] = {}
            for d = 1, 4 do
                local nr, nc = r + DR[d], c + DC[d]
                if nr >= 1 and nr <= rows and nc >= 1 and nc <= cols then
                    nb[i][d] = (nr - 1) * cols + nc
                else
                    nb[i][d] = false
                end
            end
        end
    end
    return nb
end
Solver.neighbours = neighbours

-- Edge state as seen from cell i: true (every candidate has the arm),
-- false (none has it) or nil (still open).
local function edgeState(cands, i, d)
    local list = cands[i]
    local on, off = true, true
    for k = 1, #list do
        if hasArm(list[k], d) then off = false else on = false end
    end
    if on then return true end
    if off then return false end
    return nil
end

-- Keep only cell i's candidates for which keep(mask) is true.
-- Returns "empty" on contradiction, true when something was removed.
local function filter(cands, i, keep)
    local list, out = cands[i], {}
    for k = 1, #list do
        if keep(list[k]) then out[#out + 1] = list[k] end
    end
    if #out == 0 then return "empty" end
    if #out ~= #list then
        cands[i] = out
        return true
    end
    return false
end

-- Level 1a: arc consistency between neighbouring cells, to a fixpoint.
local function propagateLocal(ctx, cands)
    local nb, n = ctx.nb, ctx.n
    local queue, queued = {}, {}
    for i = 1, n do queue[i] = i; queued[i] = true end
    local head = 1
    while head <= #queue do
        local i = queue[head]; head = head + 1
        queued[i] = false
        local need = {}
        for d = 1, 4 do
            local j = nb[i][d]
            if not j then
                need[d] = false
            else
                need[d] = edgeState(cands, j, OPP[d])
            end
        end
        local res = filter(cands, i, function(m)
            for d = 1, 4 do
                local want = need[d]
                if want ~= nil and hasArm(m, d) ~= want then return false end
            end
            return true
        end)
        if res == "empty" then return false end
        if res then
            for d = 1, 4 do
                local j = nb[i][d]
                if j and not queued[j] then
                    queue[#queue + 1] = j
                    queued[j] = true
                end
            end
        end
    end
    return true
end

-- Groups of cells joined by placed (certain) pipes. Returns comp[i] (a root
-- id), or nil when the placed pipes already close a loop.
local function components(ctx, cands)
    local nb, n = ctx.nb, ctx.n
    local parent = {}
    for i = 1, n do parent[i] = i end
    local function find(x)
        while parent[x] ~= x do
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    for i = 1, n do
        -- East and south only, so each edge is looked at once.
        for _, d in ipairs({ 2, 3 }) do
            local j = nb[i][d]
            if j and edgeState(cands, i, d) == true then
                local a, b = find(i), find(j)
                if a == b then return nil end
                parent[a] = b
            end
        end
    end
    local comp = {}
    for i = 1, n do comp[i] = find(i) end
    return comp
end

-- Force the edge (i, d) on or off, from both sides.
local function forceEdge(ctx, cands, i, d, on)
    local j = ctx.nb[i][d]
    if filter(cands, i, function(m) return hasArm(m, d) == on end) == "empty" then
        return false
    end
    if j and filter(cands, j, function(m) return hasArm(m, OPP[d]) == on end) == "empty" then
        return false
    end
    return true
end

-- One pass of the global rules. Returns ok, changed.
local function globalPass(ctx, cands, level)
    local nb, n = ctx.nb, ctx.n
    local comp = components(ctx, cands)
    if not comp then return false, false end

    -- Loops: an open edge inside one group would close a cycle.
    local changed = false
    for i = 1, n do
        for _, d in ipairs({ 2, 3 }) do
            local j = nb[i][d]
            if j and comp[i] == comp[j] and edgeState(cands, i, d) == nil then
                if not forceEdge(ctx, cands, i, d, false) then return false, false end
                changed = true
            end
        end
    end
    if changed or level < 2 then return true, changed end

    -- Ways out of each group: the open edges leaving it.
    local size, exits, last_exit, between = {}, {}, {}, {}
    for i = 1, n do
        local g = comp[i]
        size[g] = (size[g] or 0) + 1
        exits[g] = exits[g] or 0
    end
    for i = 1, n do
        for d = 1, 4 do
            local j = nb[i][d]
            if j and edgeState(cands, i, d) == nil then
                local g, h = comp[i], comp[j]
                exits[g] = exits[g] + 1
                last_exit[g] = { i, d }
                if d == 2 or d == 3 then
                    local key = g < h and (g * 65536 + h) or (h * 65536 + g)
                    between[key] = (between[key] or 0) + 1
                end
            end
        end
    end
    for g, s in pairs(size) do
        if s < n then
            if exits[g] == 0 then return false, false end
            if exits[g] == 1 then
                local e = last_exit[g]
                if not forceEdge(ctx, cands, e[1], e[2], true) then return false, false end
                changed = true
            end
        end
    end
    if changed then return true, true end

    -- Joining two groups: if the merged group would have no way out left
    -- (and isn't everything), the edge between them must stay empty. Placing
    -- the pipe also pins the two cells it touches, which can close their
    -- other open arms -- two dead ends facing each other is the usual case.
    -- Only applied when that edge is the sole link between the groups, so
    -- the count of what is left stays exact.
    local function openArms(i)
        local k = 0
        for d = 1, 4 do
            if nb[i][d] and edgeState(cands, i, d) == nil then k = k + 1 end
        end
        return k
    end
    -- Open arms of cell i other than d still possible once arm d is placed.
    local function openArmsWith(i, d)
        local possible = {}
        for _, m in ipairs(cands[i]) do
            if hasArm(m, d) then
                for e = 1, 4 do
                    if e ~= d and hasArm(m, e) then possible[e] = true end
                end
            end
        end
        local k = 0
        for e = 1, 4 do
            if possible[e] and nb[i][e] and edgeState(cands, i, e) == nil then k = k + 1 end
        end
        return k
    end
    for i = 1, n do
        for _, d in ipairs({ 2, 3 }) do
            local j = nb[i][d]
            if j and edgeState(cands, i, d) == nil then
                local g, h = comp[i], comp[j]
                local key = g < h and (g * 65536 + h) or (h * 65536 + g)
                if size[g] + size[h] < n and between[key] == 1 then
                    local left_g = exits[g] - openArms(i) + openArmsWith(i, d)
                    local left_h = exits[h] - openArms(j) + openArmsWith(j, OPP[d])
                    if left_g + left_h == 0 then
                        if not forceEdge(ctx, cands, i, d, false) then return false, false end
                        changed = true
                    end
                end
            end
        end
    end
    return true, changed
end

-- Run deduction at `level` to a fixpoint. Returns false on contradiction.
local function deduce(ctx, cands, level)
    while true do
        if not propagateLocal(ctx, cands) then return false end
        if level < 1 then return true end
        local ok, changed = globalPass(ctx, cands, level)
        if not ok then return false end
        if not changed then return true end
    end
end

local function copyCands(cands)
    local out = {}
    for i = 1, #cands do
        local src, dst = cands[i], {}
        for k = 1, #src do dst[k] = src[k] end
        out[i] = dst
    end
    return out
end

-- A full assignment is a solution when every arm meets an arm, nothing
-- points off the grid, and the pipes form one tree over every cell.
local function isTree(ctx, masks)
    local nb, n = ctx.nb, ctx.n
    local edges = 0
    for i = 1, n do
        for d = 1, 4 do
            local j = nb[i][d]
            local here = hasArm(masks[i], d)
            if not j then
                if here then return false end
            elseif here ~= hasArm(masks[j], OPP[d]) then
                return false
            elseif here and (d == 2 or d == 3) then
                edges = edges + 1
            end
        end
    end
    if edges ~= n - 1 then return false end
    local seen, stack, count = { [1] = true }, { 1 }, 0
    while #stack > 0 do
        local i = table.remove(stack)
        count = count + 1
        for d = 1, 4 do
            local j = nb[i][d]
            if j and not seen[j] and hasArm(masks[i], d) then
                seen[j] = true
                stack[#stack + 1] = j
            end
        end
    end
    return count == n
end

local function newContext(rows, cols)
    return { rows = rows, cols = cols, n = rows * cols, nb = neighbours(rows, cols) }
end

local function initialCands(shapes)
    local cands = {}
    for i = 1, #shapes do cands[i] = rotations(shapes[i]) end
    return cands
end

-- shapes: flat list of masks (any rotation). Returns true when deduction at
-- `level` alone pins every tile, plus the resulting masks.
function Solver.solveByDeduction(shapes, rows, cols, level)
    local ctx   = newContext(rows, cols)
    local cands = initialCands(shapes)
    if not deduce(ctx, cands, level) then return false end
    local masks = {}
    for i = 1, ctx.n do
        if #cands[i] ~= 1 then return false end
        masks[i] = cands[i][1]
    end
    if not isTree(ctx, masks) then return false end
    return true, masks
end

-- Number of solutions, stopping at `limit` (default 2). Second result: the
-- first solution found, as a flat list of masks.
function Solver.countSolutions(shapes, rows, cols, limit)
    limit = limit or 2
    local ctx = newContext(rows, cols)
    local count, first = 0, nil
    local function search(cands)
        if count >= limit then return end
        if not deduce(ctx, cands, 2) then return end
        local best, best_n = nil, 99
        for i = 1, ctx.n do
            local k = #cands[i]
            if k > 1 and k < best_n then best, best_n = i, k end
        end
        if not best then
            local masks = {}
            for i = 1, ctx.n do masks[i] = cands[i][1] end
            if isTree(ctx, masks) then
                count = count + 1
                if not first then first = masks end
            end
            return
        end
        for _, m in ipairs(cands[best]) do
            local nxt = copyCands(cands)
            nxt[best] = { m }
            search(nxt)
            if count >= limit then return end
        end
    end
    search(initialCands(shapes))
    return count, first
end

-- Is this full assignment of masks a solved network?
function Solver.isSolved(masks, rows, cols)
    return isTree(newContext(rows, cols), masks)
end

return Solver
