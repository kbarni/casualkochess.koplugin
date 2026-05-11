local Geom         = require("ui/geometry")
local Blitbuffer   = require("ffi/blitbuffer")
local ButtonTable  = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device       = require("device")
local Screen       = Device.screen
local UIManager    = require("ui/uimanager")
local IconWidget   = require("ui/widget/iconwidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Reversi      = require("reversigame")

local BOARD_SIZE      = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "casualchess/empty",
    [Reversi.DISC] = {
        [Reversi.WHITE] = "casualchess/wChecker",
        [Reversi.BLACK] = "casualchess/bChecker",
        rotated = {
            [Reversi.WHITE] = "casualchess/wChecker_rot",
            [Reversi.BLACK] = "casualchess/bChecker_rot",
        },
    },
}
local HINT_ICON = "casualchess/reversi_hint"

local Board = FrameContainer:extend{
    game                = nil,
    width               = 250,
    height              = 250,
    moveCallback        = nil,
    bordersize          = 0,
    padding             = 0,
    background          = Blitbuffer.COLOR_WHITE,
    board_padding       = nil,
    flipped             = false,
    rotate_top_pieces   = false,
    learning_mode       = false,
    show_selected       = true,
    previous_move_hints = false,
    opponent_hints      = false,
    check_hints         = false,
    _hint_squares       = nil,
    _previous_move_squares = nil,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then error("Reversi Board: must be initialized with a Game object") end

    local margins       = self:allMarginSizes()
    local bt_pad_v      = Screen:scaleBySize(4)
    self.board_padding  = Screen:scaleBySize(8)
    local usable_w      = self.width  - 2 * self.board_padding
    local usable_h      = self.height - self.board_padding
    local cell = math.min(
        math.floor(usable_w / BOARD_SIZE) - margins.w,
        math.floor(usable_h / BOARD_SIZE) - margins.h
    )
    self.button_size  = cell
    self.icon_height  = cell - 2 * bt_pad_v
    self._hint_squares          = {}
    self._previous_move_squares = nil

    local rank_start, rank_stop, rank_step = BOARD_SIZE - 1, 0, -1
    local file_start, file_stop, file_step = 0, BOARD_SIZE - 1, 1
    if self.flipped then
        rank_start, rank_stop, rank_step = 0, BOARD_SIZE - 1, 1
        file_start, file_stop, file_step = BOARD_SIZE - 1, 0, -1
    end

    local grid = {}
    for rank = rank_start, rank_stop, rank_step do
        local row = {}
        for file = file_start, file_stop, file_step do
            row[#row + 1] = self:createSquareButton(file, rank)
        end
        grid[#grid + 1] = row
    end

    self.table = ButtonTable:new{
        width                = cell * BOARD_SIZE,
        buttons              = grid,
        shrink_unneeded_width = false,
        zero_sep             = true,
        sep_width            = 0,
        addVerticalSpan      = function() end,
    }

    self:applySquareColors()
    local CenterContainer = require("ui/widget/container/centercontainer")
    self[1] = FrameContainer:new{
        bordersize  = 0,
        background  = self.background,
        padding     = 0,
        padding_top = self.board_padding,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = cell * BOARD_SIZE + self.board_padding },
            self.table,
        },
    }
end

function Board:setFlipped(flipped)
    flipped = flipped and true or false
    if self.flipped == flipped then return end
    self.flipped = flipped
    self:init()
    self:updateBoard()
end

function Board:setRotateTopPieces(rotate_top_pieces)
    rotate_top_pieces = rotate_top_pieces and true or false
    if self.rotate_top_pieces == rotate_top_pieces then return end
    self.rotate_top_pieces = rotate_top_pieces
    self:updateBoard()
end

function Board:createSquareButton(file, rank)
    return {
        id          = Board.toId(file, rank),
        icon        = icons.empty,
        alpha       = true,
        width       = self.button_size,
        icon_width  = self.button_size,
        icon_height = self.icon_height,
        bordersize  = Screen:scaleBySize(SELECTED_BORDER),
        margin      = 0,
        padding     = 0,
        callback    = function() self:handleClick(file, rank) end,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            local color  = Board.positionToColor(Board.idToPosition(Board.toId(file, rank)))
            button.frame.background  = color
            button.frame.border_color = color
        end
    end
end

local function overlayIcon(button, purpose, icon_name, w, h)
    local lc = button.frame[1]
    if not lc or not lc[1] then return end
    local orig = lc[1]
    local og   = orig
    if not og._is_overlay then
        og = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, orig }
        og._is_overlay    = true
        og._orig_widget   = orig
        og._overlay_icons = {}
        og._overlay_w     = w
        og._overlay_h     = h
        lc[1] = og
    end
    og._overlay_icons[purpose] = icon_name
    for i = #og, 2, -1 do og[i] = nil end
    for _, name in pairs(og._overlay_icons) do
        og[#og + 1] = IconWidget:new{ icon = name, alpha = true, width = w, height = h, is_icon = true }
    end
end

local function clearOverlay(button, purpose)
    local lc = button.frame[1]
    if not lc then return end
    local og = lc[1]
    if not (og and og._is_overlay) then return end
    og._overlay_icons[purpose] = nil
    for _, _ in pairs(og._overlay_icons) do
        for i = #og, 2, -1 do og[i] = nil end
        for _, name in pairs(og._overlay_icons) do
            og[#og + 1] = IconWidget:new{ icon = name, alpha = true, width = og._overlay_w, height = og._overlay_h, is_icon = true }
        end
        return
    end
    lc[1] = og._orig_widget
end

-- Place a disc (or clear) a square without touching overlays.
function Board:placePiece(sq, piece_type, color)
    local id = Board.chessToId(sq)
    if not id then return end
    local piece_icons = piece_type and icons[piece_type]
    local icon = (piece_icons and piece_icons[color]) or icons.empty
    if piece_icons and self.rotate_top_pieces then
        local top_color = self.flipped and Reversi.WHITE or Reversi.BLACK
        if color == top_color and piece_icons.rotated then
            icon = piece_icons.rotated[color] or icon
        end
    end
    local button     = self.table:getButtonById(id)
    button:setIcon(icon, self.button_size)
    local sq_color   = Board.positionToColor(sq)
    button.frame.background   = sq_color
    button.frame.border_color = sq_color
end

function Board:updateSquare(sq)
    local piece = self.game:get(sq)
    if piece then self:placePiece(sq, piece.type, piece.color) else self:placePiece(sq) end
end

function Board:updateBoard()
    for file = 0, BOARD_SIZE - 1 do
        for rank = 0, BOARD_SIZE - 1 do
            self:updateSquare(Board.idToPosition(Board.toId(file, rank)))
        end
    end
    -- Refresh valid-move hints (only shown when it is the human's turn).
    for _, sq in ipairs(self._hint_squares or {}) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "hint") end
    end
    self._hint_squares = {}
    if not self.game:game_over() and self.game:is_human(self.game:turn()) then
        for _, m in ipairs(self.game:moves()) do
            local id = Board.chessToId(m.to)
            if id then
                overlayIcon(self.table:getButtonById(id), "hint", HINT_ICON, self.button_size, self.icon_height)
                self._hint_squares[#self._hint_squares + 1] = m.to
            end
        end
    end
    UIManager:setDirty(self, "ui")
end

-- Direct placement: no piece-selection state needed.
function Board:handleClick(file, rank)
    if not self.game:is_human(self.game:turn()) then return end
    local sq   = Board.idToPosition(Board.toId(file, rank))
    local move = self.game:move{ from = "--", to = sq }
    if move then
        self:handleGameMove(move)
    end
end

function Board:handleGameMove(move)
    self:updateBoard()
    self:markPreviousMove(move)
    if self.moveCallback then self.moveCallback(move) end
end

-- Required by main.lua (called on reset / undo).
function Board:clearValidMoves()
    for _, sq in ipairs(self._hint_squares or {}) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "hint") end
    end
    self._hint_squares = {}
    UIManager:setDirty("all", "ui")
end

function Board:clearPreviousMoveHints()
    if not self._previous_move_squares then return end
    for _, sq in ipairs(self._previous_move_squares) do
        local id = Board.chessToId(sq)
        if id then clearOverlay(self.table:getButtonById(id), "previous") end
    end
    self._previous_move_squares = nil
    UIManager:setDirty("all", "ui")
end

function Board:markPreviousMove(move)
    self:clearPreviousMoveHints()
    if not (self.learning_mode and self.previous_move_hints and move) then return end
    if not move.to or move.to == "--" then return end
    self._previous_move_squares = { move.to }
    for _, sq in ipairs(move.flips or {}) do
        self._previous_move_squares[#self._previous_move_squares + 1] = sq
    end
    for _, sq in ipairs(self._previous_move_squares) do
        local id = Board.chessToId(sq)
        if id then
            overlayIcon(self.table:getButtonById(id), "previous", HINT_ICON, self.button_size, self.icon_height)
        end
    end
    UIManager:setDirty("all", "ui")
end

-- No-ops required by the board contract.
function Board:clearCheckHint() end
function Board:markCheckHint()  end

-- ── Coordinate helpers (same layout as other boards) ──────────────────────

function Board.toId(file, rank)
    return file * BOARD_SIZE + rank + 1
end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file = string.byte(position:sub(1,1)) - string.byte("a")
        local rank = tonumber(position:sub(2,2)) - 1
        if file >= 0 and file < BOARD_SIZE and rank >= 0 and rank < BOARD_SIZE then
            return Board.toId(file, rank)
        end
    end
end

function Board.idToPosition(id)
    local zero = id - 1
    local file = math.floor(zero / BOARD_SIZE)
    local rank = zero % BOARD_SIZE
    return string.char(string.byte("a") + file) .. tostring(rank + 1)
end

function Board.positionToColor(position)
    local id   = Board.chessToId(position)
    local file = math.floor((id - 1) / BOARD_SIZE)
    local rank = (id - 1) % BOARD_SIZE
    return (file + rank) % 2 == 0 and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_LIGHT_GRAY
end

function Board:allMarginSizes()
    self._padding_top    = self.padding_top    or self.padding
    self._padding_right  = self.padding_right  or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left   = self.padding_left   or self.padding
    return {
        w = (self.margin + self.bordersize) * 2 + self._padding_left + self._padding_right,
        h = (self.margin + self.bordersize) * 2 + self._padding_top  + self._padding_bottom,
    }
end

return Board
