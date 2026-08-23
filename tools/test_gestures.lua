-- Gesture recogniser tests. Run: luajit tools/test_gestures.lua
-- These exist because Android blocks synthetic multi-touch, so pinch cannot be
-- verified on a real device from here.
package.path = "./?.lua;" .. package.path
local gestures = require("main.gestures")

local failures = 0
local function check(name, cond, detail)
	if cond then
		print(string.format("  ok   %s", name))
	else
		failures = failures + 1
		print(string.format("  FAIL %s  %s", name, detail or ""))
	end
end

local function approx(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-6)
end

print("pinch out (fingers apart) zooms in")
do
	local g = gestures.new()
	-- Baseline frame must not move or scale anything.
	local r = g:update({ { x = 100, y = 400 }, { x = 100, y = 600 } }, 0)
	check("first frame is inert", r.zoom == 1 and r.pan_dx == 0 and r.pan_dy == 0)
	-- Separation 200 -> 400 doubles the zoom.
	r = g:update({ { x = 100, y = 300 }, { x = 100, y = 700 } }, 0)
	check("doubling separation doubles zoom", approx(r.zoom, 2.0),
		"got " .. tostring(r.zoom))
	check("anchor is the midpoint", r.anchor_x == 100 and r.anchor_y == 500)
	check("no pan when midpoint is still", r.pan_dx == 0 and r.pan_dy == 0)
end

print("pinch in (fingers together) zooms out")
do
	local g = gestures.new()
	g:update({ { x = 0, y = 0 }, { x = 0, y = 400 } }, 0)
	local r = g:update({ { x = 0, y = 100 }, { x = 0, y = 300 } }, 0)
	check("halving separation halves zoom", approx(r.zoom, 0.5), "got " .. tostring(r.zoom))
end

print("two-finger drag pans")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } }, 0)
	local r = g:update({ { x = 150, y = 430 }, { x = 350, y = 430 } }, 0)
	check("midpoint travel becomes pan", r.pan_dx == 50 and r.pan_dy == 30,
		string.format("got %s,%s", r.pan_dx, r.pan_dy))
	check("constant separation leaves zoom alone", approx(r.zoom, 1.0))
end

print("one finger pans, and a short press taps")
do
	local g = gestures.new()
	g:update({ { x = 500, y = 900 } }, 0)
	local r = g:update({ { x = 520, y = 880 } }, 0)
	check("drag pans by the delta", r.pan_dx == 20 and r.pan_dy == -20)
	r = g:update({}, 0)
	check("long drag is not a tap", r.tap_x == nil)

	local h = gestures.new()
	h:update({ { x = 500, y = 900 } }, 0)
	h:update({ { x = 502, y = 901 } }, 0)
	r = h:update({}, 0)
	check("short press taps at the release point", r.tap_x == 502 and r.tap_y == 901)
end

print("a pinch never becomes a tap")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 100, y = 600 } }, 0)
	g:update({ { x = 100, y = 399 }, { x = 100, y = 601 } }, 0)
	g:update({ { x = 100, y = 500 } }, 0)   -- one finger lifts
	local r = g:update({}, 0)               -- the other lifts
	check("no tap emitted after a pinch", r.tap_x == nil)
end

print("lifting to one finger does not lurch the map")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } }, 0)
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } }, 0)
	-- Second finger lifts; the survivor is far from the old midpoint (200,400).
	local r = g:update({ { x = 100, y = 400 } }, 0)
	check("hand-over frame emits no pan", r.pan_dx == 0 and r.pan_dy == 0,
		string.format("got %s,%s", r.pan_dx, r.pan_dy))
	r = g:update({ { x = 110, y = 400 } }, 0)
	check("panning resumes from the surviving finger", r.pan_dx == 10)
end

print("the HUD bar swallows gestures that start inside it")
do
	local g = gestures.new()
	g:update({ { x = 500, y = 50 } }, 104)
	local r = g:update({ { x = 560, y = 60 } }, 104)
	check("no pan from a drag starting on the bar", r.pan_dx == 0 and r.pan_dy == 0)
	r = g:update({}, 104)
	check("no tap from the bar either", r.tap_x == nil)
end

print(failures == 0 and "\nALL GESTURE TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
