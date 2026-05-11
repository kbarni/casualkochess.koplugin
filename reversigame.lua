local Reversi = {}
Reversi.__index = Reversi

Reversi.WHITE = "w"
Reversi.BLACK = "b"
Reversi.DISC  = "d"

local BOARD_SIZE = 8
local DIRS = { {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1} }

local function other(color)
    return color == Reversi.WHITE and Reversi.BLACK or Reversi.WHITE
end

local function square(file, rank)
    if file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coords(sq)
    if type(sq) ~= "string" or #sq ~= 2 then return nil end
    local file = string.byte(sq:sub(1,1)) - string.byte("a") + 1
    local rank = tonumber(sq:sub(2,2))
    if not file or not rank or file < 1 or file > BOARD_SIZE or rank < 1 or rank > BOARD_SIZE then return nil end
    return file, rank
end

local function copyBoard(board)
    local out = {}
    for sq, piece in pairs(board) do
        out[sq] = { type = piece.type, color = piece.color }
    end
    return out
end

local function copyFlips(flips)
    local out = {}
    for i, sq in ipairs(flips or {}) do out[i] = sq end
    return out
end

local function copyMove(move)
    local out = {}
    for k, v in pairs(move) do
        if k == "flips" then
            out[k] = copyFlips(v)
        elseif k == "before" then
            out[k] = copyBoard(v)
        else
            out[k] = v
        end
    end
    return out
end

local function copyMoves(moves)
    local out = {}
    for i, move in ipairs(moves or {}) do out[i] = copyMove(move) end
    return out
end

local function attachInstanceMethods(obj)
    obj.reset = function() return Reversi.reset(obj) end
    obj.turn  = function() return Reversi.turn(obj) end
    obj.set_human = function(a, b, c)
        local color    = (a == obj) and b or a
        local is_human = (a == obj) and c or b
        return Reversi.set_human(obj, color, is_human)
    end
    obj.is_human = function(a, b)
        local color = b or a
        return Reversi.is_human(obj, color)
    end
    obj.get = function(a, b)
        local sq = b or a
        return Reversi.get(obj, sq)
    end
    obj.board = function() return Reversi.board(obj) end
    obj.moves = function(a, b)
        local opts = b or a
        return Reversi.moves(obj, opts)
    end
    obj.move = function(a, b)
        local input = b or a
        return Reversi.move(obj, input)
    end
    obj.undo  = function() return Reversi.undo(obj) end
    obj.redo  = function() return Reversi.redo(obj) end
    obj.history    = function() return Reversi.history(obj) end
    obj.game_over  = function() return Reversi.game_over(obj) end
    obj.export_state = function() return Reversi.export_state(obj) end
    obj.load_state = function(a, b)
        local state = b or a
        return Reversi.load_state(obj, state)
    end
    obj.score = function() return Reversi.score(obj) end
end

function Reversi:new()
    local obj = {
        board_state  = {},
        self_turn    = Reversi.BLACK,
        human_player = { [Reversi.WHITE] = true, [Reversi.BLACK] = true },
        move_history = {},
        redo_stack   = {},
    }
    setmetatable(obj, Reversi)
    attachInstanceMethods(obj)
    obj:reset()
    return obj
end

function Reversi:clone()
    local obj = {
        board_state  = copyBoard(self.board_state),
        self_turn    = self.self_turn,
        human_player = {
            [Reversi.WHITE] = self.human_player[Reversi.WHITE],
            [Reversi.BLACK] = self.human_player[Reversi.BLACK],
        },
        move_history = {},
        redo_stack   = {},
    }
    setmetatable(obj, Reversi)
    attachInstanceMethods(obj)
    return obj
end

function Reversi:reset()
    self.board_state = {
        d4 = { type = Reversi.DISC, color = Reversi.WHITE },
        e4 = { type = Reversi.DISC, color = Reversi.BLACK },
        d5 = { type = Reversi.DISC, color = Reversi.BLACK },
        e5 = { type = Reversi.DISC, color = Reversi.WHITE },
    }
    self.self_turn    = Reversi.BLACK
    self.move_history = {}
    self.redo_stack   = {}
end

function Reversi:turn()    return self.self_turn end
function Reversi:set_human(color, is_human) self.human_player[color] = is_human and true or false end
function Reversi:is_human(color) return self.human_player[color] ~= false end
function Reversi:get(sq)   return self.board_state[sq] end

function Reversi:board()
    local rows = {}
    for rank = BOARD_SIZE, 1, -1 do
        local row = {}
        for file = 1, BOARD_SIZE do
            row[file] = self.board_state[square(file, rank)]
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- Returns the list of squares that would be flipped by placing `color` at `sq`.
-- Returns nil if the square is occupied, or an empty table if no flips (invalid move).
function Reversi:flipsFor(sq, color, board_state)
    board_state = board_state or self.board_state
    if board_state[sq] then return nil end
    local file, rank = coords(sq)
    if not file then return nil end

    local opponent  = other(color)
    local all_flips = {}

    for _, d in ipairs(DIRS) do
        local line = {}
        local f, r = file + d[1], rank + d[2]
        while true do
            local s = square(f, r)
            if not s then break end
            local piece = board_state[s]
            if not piece then break end
            if piece.color == opponent then
                line[#line + 1] = s
                f = f + d[1]
                r = r + d[2]
            elseif piece.color == color then
                for _, captured in ipairs(line) do
                    all_flips[#all_flips + 1] = captured
                end
                break
            else
                break
            end
        end
    end

    return all_flips
end

function Reversi:computeValidMovesFor(color, board_state)
    board_state = board_state or self.board_state
    local result = {}
    for file = 1, BOARD_SIZE do
        for rank = 1, BOARD_SIZE do
            local sq    = square(file, rank)
            local flips = self:flipsFor(sq, color, board_state)
            if flips and #flips > 0 then
                result[#result + 1] = {
                    from     = "--",
                    to       = sq,
                    color    = color,
                    flips    = flips,
                    notation = sq,
                }
            end
        end
    end
    return result
end

-- opts is accepted for interface compatibility but ignored (no source-square concept).
function Reversi:moves(opts) -- luacheck: ignore opts
    return self:computeValidMovesFor(self.self_turn)
end

function Reversi:move(input)
    local valid  = self:computeValidMovesFor(self.self_turn)
    local target = nil
    for _, m in ipairs(valid) do
        if m.to == input.to then target = m; break end
    end
    if not target then return nil end

    local before = copyBoard(self.board_state)
    local color  = self.self_turn

    self.board_state[target.to] = { type = Reversi.DISC, color = color }
    for _, sq in ipairs(target.flips) do
        self.board_state[sq] = { type = Reversi.DISC, color = color }
    end

    target.before = before
    target.color  = color
    self.move_history[#self.move_history + 1] = target
    self.redo_stack = {}

    -- Switch to opponent; if they have no moves (but game continues), switch back.
    self.self_turn = other(color)
    local next_moves = self:computeValidMovesFor(self.self_turn)
    if #next_moves == 0 then
        local orig_moves = self:computeValidMovesFor(color)
        if #orig_moves > 0 then
            target.pass_after = true
            self.self_turn = color
        end
        -- If both have no moves, game_over() will detect it.
    end

    return target
end

function Reversi:undo()
    local move = table.remove(self.move_history)
    if not move then return nil end
    self.board_state = move.before
    self.self_turn   = move.color
    self.redo_stack[#self.redo_stack + 1] = move
    return move
end

function Reversi:redo()
    local move = table.remove(self.redo_stack)
    if not move then return nil end
    return self:move{ from = move.from, to = move.to }
end

function Reversi:history()
    local out = {}
    for _, move in ipairs(self.move_history) do
        out[#out + 1] = move.notation or move.to
        if move.pass_after then
            out[#out + 1] = "(pass)"
        end
    end
    return out
end

function Reversi:score()
    local w, b = 0, 0
    for _, piece in pairs(self.board_state) do
        if piece.color == Reversi.WHITE then w = w + 1
        elseif piece.color == Reversi.BLACK then b = b + 1 end
    end
    return { w = w, b = b }
end

local function computeResult(game)
    local s = game:score()
    if     s.b > s.w then return true, "0-1", "Disc count"
    elseif s.w > s.b then return true, "1-0", "Disc count"
    else               return true, "1/2-1/2", "Equal discs" end
end

function Reversi:game_over()
    local total = 0
    for _ in pairs(self.board_state) do total = total + 1 end
    if total >= BOARD_SIZE * BOARD_SIZE then return computeResult(self) end

    if #self:computeValidMovesFor(self.self_turn) > 0 then return false end
    if #self:computeValidMovesFor(other(self.self_turn)) > 0 then return false end
    return computeResult(self)
end

function Reversi:export_state()
    return {
        version      = 1,
        board_state  = copyBoard(self.board_state),
        self_turn    = self.self_turn,
        move_history = copyMoves(self.move_history),
        redo_stack   = copyMoves(self.redo_stack),
    }
end

function Reversi:load_state(state)
    if type(state) ~= "table" or state.version ~= 1 then return false end
    if state.self_turn ~= Reversi.WHITE and state.self_turn ~= Reversi.BLACK then return false end
    if type(state.board_state) ~= "table" then return false end
    self.board_state  = copyBoard(state.board_state)
    self.self_turn    = state.self_turn
    self.move_history = copyMoves(state.move_history or {})
    self.redo_stack   = copyMoves(state.redo_stack   or {})
    return true
end

return Reversi
