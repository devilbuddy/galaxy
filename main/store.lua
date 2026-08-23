--- Shared state between the map scripts.
--
-- `script.shared_state` is enabled in game.project, so every script runs in one
-- Lua state and a required module is a single shared instance. That makes a
-- module the natural place for state the camera, the map and the HUD all need,
-- and avoids fanning the same data out over messages every frame.

local M = {}

-- The generated galaxy (see galaxy/generate.lua for its shape).
M.galaxy = nil

-- The view, published by the render script: the design width from
-- game.project, with the height derived from the framebuffer's real aspect
-- ratio. This is the space the world projection and GUI nodes live in.
--
-- Touch coordinates do NOT arrive in this space: Defold always normalises them
-- to the configured display size. `input_scale_*` converts between the two, so
-- always route action.x/action.y through M.input_point() rather than using
-- them raw. `framebuffer_*` is the real pixel size and is informational.
M.screen = {
	width = 720, height = 1280,
	input_scale_x = 1, input_scale_y = 1,
	framebuffer_width = 720, framebuffer_height = 1280,
}

-- Live camera state, written by main/camera.script and read by the render
-- script to build the projection.
M.camera = { x = 0, y = 0, zoom = 1 }

-- Currently selected star index, or nil.
M.selected = nil

-- "server" or "local": where the current galaxy came from.
M.source = nil

-- The active game's id, and the player's projected view of it.
M.game_id = nil
M.game_view = nil
M.game = nil
-- Highest turn whose events the player has already been shown.
M.seen_turn = 0

-- The server's clock, sampled on each state response and advanced locally
-- between them. Used for the "next turn in ..." countdown; the device clock
-- cannot be trusted to agree with the server's.
M.now_estimate = 0

-- Orders queued locally for the coming turn, as { from =, to =, ships = }.
-- They are only sent when the player submits, so a plan can be revised freely.
M.orders = {}
-- The system a move is being planned from, if the player has picked one.
M.order_source = nil

-- Transient status line for the HUD ("connecting...", "requesting galaxy...").
M.status = nil

-- Height of the HUD bar, in view units. The camera declines drags that start
-- inside it so panning cannot fight the controls.
M.hud_bar_height = 0

-- Bumped whenever a new galaxy is generated, so the HUD can notice.
M.revision = 0

--- Convert a touch/mouse position into view space.
function M.input_point(x, y)
	local s = M.screen
	return x * s.input_scale_x, y * s.input_scale_y
end

return M
