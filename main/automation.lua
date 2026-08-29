--- Debug-only bridge between the running game and an automation client.
--
-- The Automation Bridge extension reports GUI node bounds against Defold's
-- *configured* display, and this project does not use it: the render script
-- builds its own GUI projection (720 by an aspect-derived height) and the world
-- is drawn through a camera the render script owns. So the extension's screen
-- coordinates are the wrong space here, for exactly the reason
-- `ui.install_druid_picking` had to replace `gui.pick_node`.
--
-- Rather than have the client guess, the game publishes the one thing that
-- resolves it: the transform. From the view size, the framebuffer size and the
-- camera, a client can convert any world position to a device pixel exactly the
-- way the map does, and stop trying to infer tile positions from screenshots.
--
-- Everything here is guarded: `automation_bridge` exists only in debug builds,
-- so on a release build this module is inert and costs a nil check.

local store = require("main.store")

local M = {}

-- Four times a second. The client polls state rather than frames, and a
-- publication per frame would be sixty JSON encodes a second for a reader that
-- cannot use them.
local INTERVAL = 0.25

local bridge = nil
local timer = 0

function M.available()
	if bridge == nil then bridge = rawget(_G, "automation_bridge") or false end
	return bridge ~= false
end

--- Publish the view transform and what the player currently has selected.
function M.update(dt)
	if not M.available() then return end
	timer = timer + dt
	if timer < INTERVAL then return end
	timer = 0

	local screen = store.screen
	local cam = store.camera
	local view = store.game_view
	bridge.publish("realm.view", {
		-- The space every GUI node and the world projection live in.
		view_width = screen.width,
		view_height = screen.height,
		-- Device pixels, which is what an automation client clicks in.
		pixel_width = screen.framebuffer_width,
		pixel_height = screen.framebuffer_height,
		camera_x = cam.x,
		camera_y = cam.y,
		zoom = cam.zoom,
		-- Enough state to assert against without reading the screen.
		seed = store.realm and store.realm.seed or 0,
		turn = view and view.turn or 0,
		selected = store.selected or 0,
		selected_commander = store.selected_commander or 0,
		aiming = store.aiming and store.aiming.kind or "",
		staged_orders = store.plan_count and store.plan_count() or 0,
		commanders = view and #view.commanders or 0,
	})
end

return M
