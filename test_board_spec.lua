local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Netwalk", function()
    local Board, Solver

    setup(function()
        Board  = dofile(DIR .. "board.lua")
        Solver = dofile(DIR .. "solver.lua")
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        local b = Board:new{ n = n or 5 }
        b:generate(diff or "easy")
        return b
    end

    -- Put every tile in its solved orientation.
    local function solve(b)
        for r = 1, b.n do
            for c = 1, b.n do b.tiles[r][c] = b.solution[r][c] end
        end
    end

    describe("tile masks", function()
        it("rotates arms clockwise N->E->S->W", function()
            assert.are.equal(2, Solver.rotateCW(1))   -- N -> E
            assert.are.equal(8, Solver.rotateCW(4))   -- S -> W
            assert.are.equal(1, Solver.rotateCW(8))   -- W -> N
            assert.are.equal(6, Solver.rotateCW(3))   -- NE -> ES
        end)

        it("counter-clockwise undoes clockwise", function()
            for m = 0, 15 do
                assert.are.equal(m, Solver.rotateCCW(Solver.rotateCW(m)))
            end
        end)

        it("lists distinct rotations only", function()
            assert.are.equal(4, #Solver.rotations(1))   -- dead end
            assert.are.equal(2, #Solver.rotations(5))   -- straight
            assert.are.equal(1, #Solver.rotations(15))  -- cross
        end)
    end)

    describe("generate", function()
        it("builds a spanning tree as the solution", function()
            for _, n in ipairs(Board.SIZES) do
                local b = newBoard(n, "easy", n)
                assert.is_true(Solver.isSolved(b:_flat(b.solution), n, n))
            end
        end)

        it("scrambles: the puzzle does not start solved", function()
            for seed = 1, 30 do
                local b = newBoard(5, "easy", seed)
                assert.is_false(b:isSolved())
            end
        end)

        it("only rotates tiles: each tile is a rotation of its solution", function()
            local b = newBoard(7, "medium", 3)
            for r = 1, 7 do
                for c = 1, 7 do
                    local found = false
                    for _, m in ipairs(Solver.rotations(b.solution[r][c])) do
                        if m == b.tiles[r][c] then found = true end
                    end
                    assert.is_true(found)
                end
            end
        end)

        it("has a unique solution, confirmed by a brute-force count", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                for seed = 1, 8 do
                    for _, n in ipairs({ 5, 7, 9, 11 }) do
                        local b = newBoard(n, diff, seed * 13 + n)
                        local count = Solver.countSolutions(b:_flat(b.tiles), n, n, 2)
                        assert.are.equal(1, count, diff .. " " .. n .. " seed " .. seed)
                    end
                end
            end
        end)

        it("rates difficulty by the reasoning needed", function()
            for seed = 1, 15 do
                local e = newBoard(7, "easy", seed)
                assert.is_true(Solver.solveByDeduction(e:_flat(e.tiles), 7, 7, 0))
                local m = newBoard(7, "medium", seed)
                local flat = m:_flat(m.tiles)
                assert.is_true(Solver.solveByDeduction(flat, 7, 7, 1))
                assert.is_false(Solver.solveByDeduction(flat, 7, 7, 0))
                local h = newBoard(7, "hard", seed)
                flat = h:_flat(h.tiles)
                assert.is_true(Solver.solveByDeduction(flat, 7, 7, 2))
                assert.is_false(Solver.solveByDeduction(flat, 7, 7, 0))
            end
        end)

        it("reaches the hard band (needs group-exit reasoning) on most seeds", function()
            local strict = 0
            for seed = 1, 20 do
                local h = newBoard(9, "hard", seed)
                if not Solver.solveByDeduction(h:_flat(h.tiles), 9, 9, 1) then
                    strict = strict + 1
                end
            end
            assert.is_true(strict >= 14, "only " .. strict .. "/20")
        end)
    end)

    describe("solver deductions", function()
        it("counts solutions exactly like brute force on small grids", function()
            -- Enumerate every rotation of every tile and count the networks
            -- that are valid trees; the solver must agree (with no limit).
            local function brute(shapes, rows, cols)
                local opts, pick, count = {}, {}, 0
                for i = 1, #shapes do opts[i] = Solver.rotations(shapes[i]) end
                local function rec(i)
                    if i > #shapes then
                        if Solver.isSolved(pick, rows, cols) then count = count + 1 end
                        return
                    end
                    for _, m in ipairs(opts[i]) do pick[i] = m; rec(i + 1) end
                end
                rec(1)
                return count
            end
            math.randomseed(99)
            for _ = 1, 5 do
                local shapes = Board.randomTree(3, 5)
                assert.are.equal(brute(shapes, 3, 3), Solver.countSolutions(shapes, 3, 3, 1000))
            end
            -- Shapes that cannot form a tree at all: four dead ends.
            assert.are.equal(0, Solver.countSolutions({ 1, 1, 1, 1 }, 2, 2, 10))
            assert.are.equal(0, brute({ 1, 1, 1, 1 }, 2, 2))
        end)

        it("solves a strip by local rules", function()
            -- 1x3 strip: dead end, straight, dead end has one answer.
            local ok, masks = Solver.solveByDeduction({ 2, 5, 8 }, 1, 3, 0)
            assert.is_true(ok)
            assert.are.same({ 2, 10, 8 }, masks)
        end)
    end)

    describe("win detection", function()
        it("accepts the stored solution", function()
            local b = newBoard(5, "easy", 1)
            solve(b)
            assert.is_true(b:isSolved())
            assert.are.equal(25, b:countPowered())
        end)

        it("accepts a straight pipe turned half a turn", function()
            local b = newBoard(7, "easy", 2)
            solve(b)
            -- Find a straight and turn it 180 degrees: same mask, still solved.
            for r = 1, 7 do
                for c = 1, 7 do
                    local m = b.tiles[r][c]
                    if m == 5 or m == 10 then
                        b.tiles[r][c] = Solver.rotateCW(Solver.rotateCW(m))
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)

        it("accepts any valid network, not only the stored one", function()
            -- The win check never reads the stored solution.
            local b = Board:new{ n = 2 }
            b.src_r, b.src_c = 1, 1
            b.solution = { { 1, 1 }, { 1, 1 } }
            b.tiles    = { { 6, 12 }, { 1, 1 } }
            b.locked   = { { false, false }, { false, false } }
            assert.is_true(b:isSolved())
        end)

        it("rejects a loose end, a loop and a split network", function()
            local b = Board:new{ n = 2 }
            b.locked = { { false, false }, { false, false } }
            b.tiles = { { 6, 12 }, { 3, 9 } }   -- closed ring: loop
            assert.is_false(b:isSolved())
            b.tiles = { { 2, 8 }, { 2, 8 } }    -- two separate pairs
            assert.is_false(b:isSolved())
            b.tiles = { { 6, 12 }, { 1, 1 } }   -- a U: valid
            assert.is_true(b:isSolved())
            b.tiles = { { 6, 12 }, { 4, 1 } }   -- (2,1) points off the grid
            assert.is_false(b:isSolved())
        end)
    end)

    describe("moves", function()
        it("rotate turns the tile and counts a move; undo restores", function()
            local b = newBoard(5, "easy", 4)
            local r, c
            for rr = 1, 5 do
                for cc = 1, 5 do
                    if not r and Solver.rotateCW(b.tiles[rr][cc]) ~= b.tiles[rr][cc] then r, c = rr, cc end
                end
            end
            local before = b.tiles[r][c]
            assert.is_true(b:rotate(r, c))
            assert.are.equal(Solver.rotateCW(before), b.tiles[r][c])
            assert.are.equal(1, b.moves)
            assert.is_true(b:undo())
            assert.are.equal(before, b.tiles[r][c])
            assert.are.equal(0, b.moves)
            assert.is_true(b:rotate(r, c, true))
            assert.are.equal(Solver.rotateCCW(before), b.tiles[r][c])
        end)

        it("a locked tile does not turn; locking is undoable", function()
            local b = newBoard(5, "easy", 5)
            assert.is_true(b:toggleLock(1, 1))
            assert.is_true(b.locked[1][1])
            local before = b.tiles[1][1]
            assert.is_false(b:rotate(1, 1))
            assert.are.equal(before, b.tiles[1][1])
            assert.is_true(b:undo())
            assert.is_false(b.locked[1][1])
            assert.are.equal(0, b.moves)
        end)

        it("refuses moves once solved", function()
            local b = newBoard(5, "easy", 6)
            solve(b)
            assert.is_false(b:rotate(1, 1))
            assert.is_false(b:toggleLock(1, 1))
        end)
    end)

    describe("hints", function()
        it("each fill turns a wrong tile right and locks it, until solved", function()
            local b = newBoard(7, "medium", 7)
            local guard = 0
            while not b:isSolved() and guard < 100 do
                local step = b:findHint()
                assert.is_not_nil(step)
                assert.are.equal("fill", step.kind)
                assert.are_not.equal(b.solution[step.r][step.c], b.tiles[step.r][step.c])
                assert.is_true(b:applyHint(step))
                assert.are.equal(b.solution[step.r][step.c], b.tiles[step.r][step.c])
                assert.is_true(b.locked[step.r][step.c])
                guard = guard + 1
            end
            assert.is_true(b:isSolved())
        end)

        it("reports a tile locked the wrong way first, and unlocks it", function()
            local b = newBoard(5, "easy", 8)
            local r, c
            for rr = 1, 5 do
                for cc = 1, 5 do
                    if not r and b.tiles[rr][cc] ~= b.solution[rr][cc] then r, c = rr, cc end
                end
            end
            b:toggleLock(r, c)
            local step = b:findHint()
            assert.are.equal("mistake", step.kind)
            assert.are.equal(r, step.r)
            assert.are.equal(c, step.c)
            assert.is_true(b:applyHint(step))
            assert.is_false(b.locked[r][c])
        end)

        it("hint steps are undoable and are not counted as moves", function()
            local b = newBoard(5, "easy", 9)
            local step = b:findHint()
            local before = b.tiles[step.r][step.c]
            b:applyHint(step)
            assert.are.equal(0, b.moves)
            b:undo()
            assert.are.equal(before, b.tiles[step.r][step.c])
            assert.is_false(b.locked[step.r][step.c])
        end)
    end)

    describe("powered cells", function()
        it("always includes the source", function()
            local b = newBoard(5, "easy", 10)
            local powered = b:getPowered()
            assert.is_true(powered[b.src_r][b.src_c])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips tiles, locks, solution and counters", function()
            local b = newBoard(7, "hard", 11)
            b:rotate(1, 1)
            b:toggleLock(2, 2)
            local data = b:serialize()
            local b2 = Board:new()
            assert.is_true(b2:load(data))
            assert.are.equal(7, b2.n)
            assert.are.equal("hard", b2.difficulty)
            assert.are.same(b.tiles, b2.tiles)
            assert.are.same(b.solution, b2.solution)
            assert.are.same(b.locked, b2.locked)
            assert.are.equal(b.moves, b2.moves)
            assert.is_true(b2:canUndo())
            assert.is_true(b2:undo())
        end)

        it("rejects missing or truncated data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            assert.is_false(b:load({ n = 5, tiles = { 1, 2 }, solution = { 1, 2 } }))
        end)
    end)
    -- 1.1.0: faster rating (Solver.rate, incremental local rule).
    describe("generator speed-up (1.1.0)", function()
        it("builds the same puzzles per seed as 1.0.x", function()
            -- Fingerprints taken with the 1.0.3 generator under this same
            -- interpreter (math.random differs between Lua and LuaJIT).
            local want = { 767384595, 603765974, 74585123, 43966375 }
            local cfgs = { {5, "easy", 1}, {7, "medium", 2}, {9, "hard", 3}, {11, "hard", 4} }
            for k, cfg in ipairs(cfgs) do
                math.randomseed(cfg[3])
                local b = Board:new{ n = cfg[1] }
                b:generate(cfg[2])
                local h = 0
                for r = 1, cfg[1] do
                    for c = 1, cfg[1] do
                        h = (h * 31 + b.tiles[r][c] * 16 + b.solution[r][c]) % 1000000007
                    end
                end
                assert.are.equal(want[k], h, "config " .. k)
            end
        end)

        it("Solver.rate is the lowest level solveByDeduction cracks", function()
            local randomTree
            local i = 1
            while true do
                local name, v = debug.getupvalue(Board.generate, i)
                if not name then break end
                if name == "randomTree" then randomTree = v end
                i = i + 1
            end
            assert.is_function(randomTree)
            local seen = {}
            for seed = 1, 60 do
                math.randomseed(seed)
                local n = ({ 5, 7, 9 })[seed % 3 + 1]
                local mid = math.floor((n + 1) / 2)
                local shapes = randomTree(n, (mid - 1) * n + mid)
                for q = 1, #shapes do
                    for _ = 1, math.random(0, 3) do shapes[q] = Solver.rotateCW(shapes[q]) end
                end
                local fresh
                for level = 0, 2 do
                    if Solver.solveByDeduction(shapes, n, n, level) then fresh = level; break end
                end
                assert.are.equal(fresh, Solver.rate(shapes, n, n, 2), "seed " .. seed)
                seen[tostring(fresh)] = true
            end
            assert.is_true(seen["0"] and seen["1"])
        end)

        it("reports progress and stays quick on 11x11 Hard", function()
            local calls = 0
            local t0 = os.clock()
            for seed = 1, 3 do
                math.randomseed(seed)
                local b = Board:new{ n = 11 }
                b:generate("hard", function(f)
                    assert.is_true(f >= 0 and f <= 1)
                    calls = calls + 1
                end)
            end
            assert.is_true(calls > 0)
            -- ~20 ms each in LuaJIT; very generous for plain Lua.
            assert.is_true(os.clock() - t0 < 10)
        end)
    end)
end)
