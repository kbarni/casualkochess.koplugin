local Game = require("foxhoundgame")

local AI = {}

local function rankOf(sq)
    return tonumber(sq and sq:sub(2, 2)) or 0
end

local function fileOf(sq)
    if not sq then return 0 end
    return string.byte(sq:sub(1, 1)) - string.byte("a") + 1
end

-- --------------------------------------------------------------------------
-- Position evaluation, from `color`'s perspective (positive = good for color)
-- --------------------------------------------------------------------------
local function evaluate(game, color)
    local fox = game:fox_square()
    if not fox then return color == Game.BLACK and 100000 or -100000 end

    local fox_rank = rankOf(fox)
    local fox_file = fileOf(fox)

    -- Split mobility into forward (toward rank 8) and backward
    local clone = game:clone()
    clone.self_turn = Game.WHITE
    local all_fox_moves = clone:moves({ verbose = true })
    clone.self_turn = Game.BLACK
    local all_hound_moves = clone:moves({ verbose = true })

    local fox_forward = 0
    local fox_backward = 0
    for _, m in ipairs(all_fox_moves) do
        if rankOf(m.to) > fox_rank then
            fox_forward = fox_forward + 1
        else
            fox_backward = fox_backward + 1
        end
    end

    -- Base score from fox's perspective
    local score = fox_rank * 120       -- advancement toward rank 8 (primary goal)
                + fox_forward * 50     -- forward mobility: crucial for escape
                + fox_backward * 10    -- backward mobility: evasion / re-positioning
                - #all_hound_moves * 2 -- hound mobility: minor factor now

    -- Edge penalty: fox is easier to trap on/near edges (fewer escape diagonals)
    if fox_file == 1 or fox_file == 8 then
        score = score - 50
    elseif fox_file == 2 or fox_file == 7 then
        score = score - 25
    end

    -- Hound evaluation
    local hounds_ahead = {}            -- list for wall detection
    local file_coverage = {}           -- set of files with hounds ahead of fox
    local left_diag_blocked = false    -- hound on the left-forward diagonal path
    local right_diag_blocked = false   -- hound on the right-forward diagonal path

    for sq, piece in pairs(game.board_state) do
        if piece.type == Game.HOUND then
            local hf = fileOf(sq)
            local hr = rankOf(sq)

            if hr >= fox_rank then
                -- Hound at or ahead of the fox (blocking position)
                hounds_ahead[#hounds_ahead + 1] = { file = hf, rank = hr }
                file_coverage[hf] = true

                -- Direct diagonal blocking: does this hound sit on one of the two
                -- forward-diagonal paths from the fox to rank 8?
                -- Left path:  (f-1, r+1), (f-2, r+2), ...
                -- Right path: (f+1, r+1), (f+2, r+2), ...
                local rank_diff = hr - fox_rank
                local file_diff = hf - fox_file

                if rank_diff > 0 and math.abs(file_diff) == rank_diff then
                    if file_diff < 0 then
                        left_diag_blocked = true
                    else
                        right_diag_blocked = true
                    end
                end

                -- Proximity penalty: hound close to the fox
                local file_dist = math.abs(hf - fox_file)
                if file_dist <= 1 and rank_diff <= 2 then
                    score = score - 35   -- directly threatening
                elseif file_dist <= 2 and rank_diff <= 3 then
                    score = score - 15   -- nearby threat
                end
            else
                -- Hound behind the fox: useless for blocking
                score = score + 45
            end
        end
    end

    -- Penalty for blocked forward diagonals
    if left_diag_blocked and right_diag_blocked then
        score = score - 120  -- both escape routes cut off
    elseif left_diag_blocked or right_diag_blocked then
        score = score - 40   -- one escape route cut off
    end

    -- Wall strength: number of distinct files with hound coverage ahead
    local covered_count = 0
    for _ in pairs(file_coverage) do
        covered_count = covered_count + 1
    end
    score = score - covered_count * 15

    -- Consecutive-file wall detection (hounds on adjacent dark squares
    -- form a coordinated blockade)
    table.sort(hounds_ahead, function(a, b) return a.file < b.file end)

    local best_wall = #hounds_ahead > 0 and 1 or 0
    local cur_wall = best_wall
    for i = 2, #hounds_ahead do
        local gap = hounds_ahead[i].file - hounds_ahead[i - 1].file
        -- On the dark-square play area (the game uses only one color),
        -- adjacent files differ by ≤ 2 (dark squares at any rank are
        -- every other file).
        if gap <= 2 then
            cur_wall = cur_wall + 1
            if cur_wall > best_wall then best_wall = cur_wall end
        else
            cur_wall = 1
        end
    end

    -- Bonus for consecutive-file wall (coordinated hound blockade)
    if best_wall >= 4 then
        score = score - 60
    elseif best_wall == 3 then
        score = score - 35
    elseif best_wall == 2 then
        score = score - 15
    end

    return color == Game.WHITE and score or -score
end

-- --------------------------------------------------------------------------
-- Terminal score with ply adjustment: prefer faster wins, slower losses
-- --------------------------------------------------------------------------
local function terminalScore(result, color, ply)
    local winner = result == "1-0" and Game.WHITE or Game.BLACK
    if winner == color then
        return 100000 - ply  -- prefer faster wins
    else
        return -100000 + ply -- prefer slower losses (fight on)
    end
end

-- --------------------------------------------------------------------------
-- Alpha-beta search with move ordering
-- --------------------------------------------------------------------------
local function search(game, depth, alpha, beta, color, ply)
    local over, result = game:game_over()
    if over then return terminalScore(result, color, ply) end
    if depth <= 0 then return evaluate(game, color) end

    local moves = game:moves({ verbose = true })

    -- Move ordering: examine the most promising moves first for the side
    -- whose turn it is, to maximise alpha-beta pruning.
    --   Fox to move    → prefer higher rank (advancing toward rank 8)
    --   Hounds to move → prefer lower rank (advancing toward the fox)
    if #moves >= 2 then
        if game:turn() == Game.WHITE then
            table.sort(moves, function(a, b)
                return rankOf(a.to) > rankOf(b.to)
            end)
        else
            table.sort(moves, function(a, b)
                return rankOf(a.to) < rankOf(b.to)
            end)
        end
    end

    if game:turn() == color then
        -- Maximising node (AI to move)
        local best = -math.huge
        for _, move in ipairs(moves) do
            local clone = game:clone()
            clone:move{ from = move.from, to = move.to }
            local s = search(clone, depth - 1, alpha, beta, color, ply + 1)
            if s > best then best = s end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
        return best
    else
        -- Minimising node (opponent to move)
        local best = math.huge
        for _, move in ipairs(moves) do
            local clone = game:clone()
            clone:move{ from = move.from, to = move.to }
            local s = search(clone, depth - 1, alpha, beta, color, ply + 1)
            if s < best then best = s end
            if best < beta then beta = best end
            if alpha >= beta then break end
        end
        return best
    end
end

-- --------------------------------------------------------------------------
-- Public API: pick the best move for the current position
-- --------------------------------------------------------------------------
function AI.bestMove(game, depth, blunder_chance)
    if game.setup_pending then return nil end
    local moves = game:moves({ verbose = true })
    if #moves == 0 then return nil end

    blunder_chance = tonumber(blunder_chance) or 0
    if blunder_chance > 0 and math.random() < blunder_chance then
        return moves[math.random(#moves)]
    end

    depth = tonumber(depth) or 5
    if depth == 0 then depth = 8 end
    depth = math.max(1, math.min(8, depth + 1))

    local color = game:turn()
    local best = {}
    local best_score = -math.huge
    for _, move in ipairs(moves) do
        local clone = game:clone()
        clone:move{ from = move.from, to = move.to }
        local score = search(clone, depth - 1, -math.huge, math.huge, color, 1)
        if score > best_score then
            best_score = score
            best = { move }
        elseif score == best_score then
            best[#best + 1] = move
        end
    end

    return best[math.random(#best)]
end

return AI
