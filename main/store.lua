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

-- Standing choices the player has changed but not yet submitted. Nil means
-- "unchanged"; they are folded into the order batch on submit alongside the
-- movement orders, so one SEND covers the whole plan.
M.pending_research = nil
M.pending_share = nil

-- What the next planned move sends: warships, or freighters to open a trade
-- route. The HUD toggles it; plan_orders reads it.
M.order_mode = "move"

-- The race chosen in the lobby, remembered between screens so creating and
-- joining agree without threading it through Monarch.
M.race = nil

-- Transient status line for the HUD ("connecting...", "requesting galaxy...").
M.status = nil

-- Height of the bottom HUD bar, in view units. Used only to frame the map in
-- the space the player can actually see; see hud_zones for input.
M.hud_bar_height = 0

-- Device safe-area insets, in view units (main/safearea.lua). The world draws
-- edge to edge - there are no letterbox bars - so these exist purely to keep
-- chrome out from under a notch or a gesture strip. Every screen adds them to
-- its outer margin, and re-lays-out when `safe_revision` changes, because the
-- platform does not know the real values for the first couple of frames.
M.safe = { top = 0, bottom = 0, left = 0, right = 0 }
M.safe_revision = 0

-- Rectangles {x0, y0, x1, y1} in view space that the HUD occupies. The camera
-- declines any gesture starting inside one, rather than relying on winning the
-- input-focus race with the GUI - acquisition order between them is not
-- guaranteed. The HUD republishes these whenever it lays out.
M.hud_zones = {}

-- Bumped whenever a new galaxy is generated, so the HUD can notice.
M.revision = 0

--- Convert a touch/mouse position into view space.
function M.input_point(x, y)
	local s = M.screen
	return x * s.input_scale_x, y * s.input_scale_y
end

return M
