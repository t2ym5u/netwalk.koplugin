-- Difficulty guarantees for Netwalk (see docs/dev/TESTING.md, "Difficulty
-- specs"): every size x level has one solution (brute-force count) and is
-- cracked by the game's own deduction at its level and not below (Easy:
-- local rules only; Medium needs loop avoidance; Hard needs group exits on
-- most seeds), levels are ordered on average at every size, a seed gives
-- the same puzzle, and generation is quick and never reads the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

local LEVELS = { "easy", "medium", "hard" }

describe("Netwalk difficulty", function()
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

    it("the level table is ordered", function()
        local e, m, h = Board.LEVELS.easy, Board.LEVELS.medium, Board.LEVELS.hard
        assert.is_true(e.solve < m.solve and m.solve < h.solve)
        assert.are.equal(m.solve - 1, m.beat)
        assert.are.equal(h.solve - 1, h.beat)
    end)

    -- moved from test_board_spec.lua
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

    -- moved from test_board_spec.lua
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

    -- moved from test_board_spec.lua
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

    it("levels are ordered on the deduction level needed, on average, at every size", function()
        for _, n in ipairs(Board.SIZES) do
            local avg = {}
            for _, diff in ipairs(LEVELS) do
                local sum = 0
                for seed = 1, 8 do
                    local b = newBoard(n, diff, seed * 37 + n)
                    local level = Solver.rate(b:_flat(b.tiles), n, n, 2)
                    assert.is_truthy(level, ("%d %s seed %d not cracked by deduction"):format(n, diff, seed))
                    assert.is_true(level <= Board.LEVELS[diff].solve)
                    sum = sum + level
                end
                avg[diff] = sum / 8
            end
            assert.are.equal(0, avg.easy)
            assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                ("%d: %.2f/%.2f/%.2f"):format(n, avg.easy, avg.medium, avg.hard))
        end
    end)

    it("a seed always gives the same puzzle", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs(LEVELS) do
                local a, b = newBoard(n, diff, 2024 + n), newBoard(n, diff, 2024 + n)
                assert.are.same(a.solution, b.solution)
                assert.are.same(a.tiles, b.tiles)
            end
        end
    end)

    it("generation never reads the clock, and stays quick", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs(LEVELS) do
                local worst = 0
                for seed = 1, 3 do
                    local t0 = os.clock()
                    local reads = clockReads(function() newBoard(n, diff, seed * 11 + n) end)
                    worst = math.max(worst, os.clock() - t0)
                    assert.are.equal(0, reads, ("%d %s read the clock"):format(n, diff))
                end
                -- ~0.05 s worst on a desktop (11x11 hard)
                assert.is_true(worst < 2, ("%d %s took %.2f s"):format(n, diff, worst))
            end
        end
    end)
end)
