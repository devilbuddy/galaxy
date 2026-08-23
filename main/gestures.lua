--- Touch gesture recognition: pan, pinch-zoom and tap.
--
-- Deliberately free of any engine dependency. Multi-touch cannot be injected
-- into an Android device from adb (SELinux blocks /dev/input), so the only way
-- to actually verify pinch behaviour is to drive this state machine directly
-- from a test - see tools/test_gestures.lua. The caller applies whatever this
-- reports; it never touches the camera itself.

local M = {}

local sqrt, abs, huge = math.sqrt, math.abs, math.huge

local Recognizer = {}
Recognizer.__index = Recognizer

--- @param opts.tap_slop  total travel, in view units, still counted as a tap
--- @param opts.dead_zone ignore pinch scale changes below this distance
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		tap_slop = opts.tap_slop or 12,
		dead_zone = opts.dead_zone or 1,
		pinching = false,
		single = nil,
		travel = 0,
		blocked = false,
	}, Recognizer)
end

--- Feed one frame of active touch points.
--
-- @param points   array of {x=, y=}, already in view space, lifted fingers removed
-- @param blocked_below  y below which a gesture is ignored (the HUD bar)
-- @return a table describing what happened this frame:
--   pan_dx, pan_dy   view-space translation of the gesture (may be 0)
--   zoom             multiplicative scale factor (1 when unchanged)
--   anchor_x/y       the point the zoom should be centred on
--   tap_x/y          set only on the frame a tap completes
function Recognizer:update(points, blocked_below)
	blocked_below = blocked_below or 0
	local n = #points
	local out = { pan_dx = 0, pan_dy = 0, zoom = 1 }

	if n >= 2 then
		local a, b = points[1], points[2]
		local mx, my = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
		local dx, dy = a.x - b.x, a.y - b.y
		local dist = sqrt(dx * dx + dy * dy)

		if not self.pinching then
			-- First frame of the gesture only establishes the baseline. Acting
			-- on it would apply a spurious jump equal to wherever the second
			-- finger happened to land.
			self.pinching = true
		else
			if dist > self.dead_zone and self.prev_dist > self.dead_zone then
				out.zoom = dist / self.prev_dist
			end
			-- The midpoint's travel pans as well, which is what makes a pinch
			-- feel like grabbing the map rather than operating a slider.
			out.pan_dx = mx - self.prev_mx
			out.pan_dy = my - self.prev_my
		end
		out.anchor_x, out.anchor_y = mx, my
		self.prev_dist, self.prev_mx, self.prev_my = dist, mx, my
		self.single = nil
		-- However little the fingers moved, a pinch is never a tap.
		self.travel = huge

	elseif n == 1 then
		local p = points[1]
		if self.pinching then
			-- Pinch ended with one finger still down. Re-anchor on it, or the
			-- map lurches by the distance from the old midpoint to this finger.
			self.pinching = false
			self.single = { x = p.x, y = p.y }
		elseif not self.single then
			self.single = { x = p.x, y = p.y }
			self.travel = 0
			self.blocked = p.y <= blocked_below
		else
			local dx, dy = p.x - self.single.x, p.y - self.single.y
			self.travel = self.travel + abs(dx) + abs(dy)
			if not self.blocked then
				out.pan_dx, out.pan_dy = dx, dy
			end
			self.single.x, self.single.y = p.x, p.y
		end

	else
		if self.single and not self.pinching
			and self.travel < self.tap_slop and not self.blocked then
			out.tap_x, out.tap_y = self.single.x, self.single.y
		end
		self.single = nil
		self.pinching = false
		self.blocked = false
	end

	return out
end

return M
