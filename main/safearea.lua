--- Device safe-area insets, in this project's view units.
--
-- The extension runs in **custom mode** (`safearea.resize_game_view = 0` in
-- game.project), so the game still draws edge to edge and there are no letterbox
-- bars: the world, the nebula and the starfield fill the whole screen including
-- the notch. What the insets are for is keeping the *chrome* out from under the
-- hardware - cards, buttons and text sit inside them, and only the map is
-- allowed behind a cutout.
--
-- Two things make this more than one function call:
--
--   * The values arrive in **framebuffer pixels**, and every layout number in
--     this project is in view units, so they have to be converted through the
--     same ratio `store.screen` already carries.
--   * They are not ready at startup. `get_insets` reports NOT_READY_YET for up
--     to a couple of hundred milliseconds, and a layout built from the zeroes it
--     returns in the meantime would be wrong and never corrected. So this polls
--     until the status settles and bumps `store.safe_revision`, which is what
--     screens watch to know they should lay out again.

local store = require("main.store")

local M = {}

-- Stop asking once the platform has said either "here they are" or "not
-- supported"; only NOT_READY_YET is worth retrying.
local POLL_SECONDS = 0.1

local settled = false
local timer = 0

--- Is the extension present at all? It is not on desktop builds.
local function available()
	return rawget(_G, "safearea") ~= nil
end

--- Convert framebuffer pixels into view units.
--
-- The vertical and horizontal ratios differ: the view is the design width by
-- an aspect-derived height, so a pixel is not square in view space.
local function to_view(insets)
	local s = store.screen
	local fw = s.framebuffer_width or s.width
	local fh = s.framebuffer_height or s.height
	local sx = (fw > 0) and (s.width / fw) or 1
	local sy = (fh > 0) and (s.height / fh) or 1
	return {
		top = (insets.top or 0) * sy,
		bottom = (insets.bottom or 0) * sy,
		left = (insets.left or 0) * sx,
		right = (insets.right or 0) * sx,
	}
end

local function publish(safe)
	local previous = store.safe
	if previous
		and math.abs(previous.top - safe.top) < 0.5
		and math.abs(previous.bottom - safe.bottom) < 0.5
		and math.abs(previous.left - safe.left) < 0.5
		and math.abs(previous.right - safe.right) < 0.5 then
		return false
	end
	store.safe = safe
	store.safe_revision = (store.safe_revision or 0) + 1
	-- Logged like the galaxy digest is: it is the only way to tell a real inset
	-- from the zeroes returned when the extension is missing or not ready.
	print(string.format("safearea: top %.0f  bottom %.0f  left %.0f  right %.0f (view units)",
		safe.top, safe.bottom, safe.left, safe.right))
	return true
end

--- Ask the platform now. Returns true when the values changed.
function M.refresh()
	if not available() then
		return publish({ top = 0, bottom = 0, left = 0, right = 0 })
	end
	local insets, status = safearea.get_insets()
	if status == safearea.STATUS_NOT_READY_YET then
		return false
	end
	settled = true
	return publish(to_view(insets or {}))
end

--- Poll until the values settle, and keep watching for rotation.
-- Call from the update of something that outlives every screen.
function M.update(dt)
	if settled then return false end
	timer = timer + dt
	if timer < POLL_SECONDS then return false end
	timer = 0
	return M.refresh()
end

--- Re-query after a window change. A fold, a rotation or a resize moves the
--- cutout, and the cached values would otherwise be stale for the rest of the
--- session.
function M.invalidate()
	settled = false
	timer = POLL_SECONDS
end

--- Has the platform given a final answer yet? Screens that build once wait for
--- this rather than laying out against the zeroes returned in the meantime.
function M.ready()
	return settled
end

--- Start listening. Safe to call more than once.
function M.install()
	if M._installed then return end
	M._installed = true
	M.refresh()
	if window and window.set_listener then
		window.set_listener(function(_, event)
			if event == window.WINDOW_EVENT_RESIZED then
				M.invalidate()
			end
		end)
	end
end

return M
