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
	local r = g:update({ { x = 100, y = 400 }, { x = 100, y = 600 } })
	check("first frame is inert", r.zoom == 1 and r.pan_dx == 0 and r.pan_dy == 0)
	-- Separation 200 -> 400 doubles the zoom.
	r = g:update({ { x = 100, y = 300 }, { x = 100, y = 700 } })
	check("doubling separation doubles zoom", approx(r.zoom, 2.0),
		"got " .. tostring(r.zoom))
	check("anchor is the midpoint", r.anchor_x == 100 and r.anchor_y == 500)
	check("no pan when midpoint is still", r.pan_dx == 0 and r.pan_dy == 0)
end

print("pinch in (fingers together) zooms out")
do
	local g = gestures.new()
	g:update({ { x = 0, y = 0 }, { x = 0, y = 400 } })
	local r = g:update({ { x = 0, y = 100 }, { x = 0, y = 300 } })
	check("halving separation halves zoom", approx(r.zoom, 0.5), "got " .. tostring(r.zoom))
end

print("two-finger drag pans")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } })
	local r = g:update({ { x = 150, y = 430 }, { x = 350, y = 430 } })
	check("midpoint travel becomes pan", r.pan_dx == 50 and r.pan_dy == 30,
		string.format("got %s,%s", r.pan_dx, r.pan_dy))
	check("constant separation leaves zoom alone", approx(r.zoom, 1.0))
end

print("one finger pans, and a short press taps")
do
	local g = gestures.new()
	g:update({ { x = 500, y = 900 } })
	local r = g:update({ { x = 520, y = 880 } })
	check("drag pans by the delta", r.pan_dx == 20 and r.pan_dy == -20)
	r = g:update({})
	check("long drag is not a tap", r.tap_x == nil)

	local h = gestures.new()
	h:update({ { x = 500, y = 900 } })
	h:update({ { x = 502, y = 901 } })
	r = h:update({})
	check("short press taps at the release point", r.tap_x == 502 and r.tap_y == 901)
end

print("a pinch never becomes a tap")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 100, y = 600 } })
	g:update({ { x = 100, y = 399 }, { x = 100, y = 601 } })
	g:update({ { x = 100, y = 500 } })   -- one finger lifts
	local r = g:update({})               -- the other lifts
	check("no tap emitted after a pinch", r.tap_x == nil)
end

print("lifting to one finger does not lurch the map")
do
	local g = gestures.new()
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } })
	g:update({ { x = 100, y = 400 }, { x = 300, y = 400 } })
	-- Second finger lifts; the survivor is far from the old midpoint (200,400).
	local r = g:update({ { x = 100, y = 400 } })
	check("hand-over frame emits no pan", r.pan_dx == 0 and r.pan_dy == 0,
		string.format("got %s,%s", r.pan_dx, r.pan_dy))
	r = g:update({ { x = 110, y = 400 } })
	check("panning resumes from the surviving finger", r.pan_dx == 10)
end

print("HUD chrome swallows gestures that start inside it")
do
	-- The interface has chrome at the bottom, at the top, and floating in the
	-- middle, so the exclusion is a list of rectangles rather than one "below
	-- this y" - which only ever covered the bottom bar.
	local BOTTOM = { 0, 0, 720, 148 }
	local TOP = { 0, 1400, 720, 1560 }
	local CARD = { 24, 900, 696, 1080 }
	local zones = { BOTTOM, TOP, CARD }

	local g = gestures.new()
	g:update({ { x = 500, y = 50 } }, zones)
	local r = g:update({ { x = 560, y = 60 } }, zones)
	check("no pan from a drag starting on the bottom bar",
		r.pan_dx == 0 and r.pan_dy == 0)
	r = g:update({}, zones)
	check("no tap from the bottom bar either", r.tap_x == nil)

	local t = gestures.new()
	t:update({ { x = 300, y = 1500 } }, zones)
	r = t:update({ { x = 340, y = 1490 } }, zones)
	check("no pan from a drag starting on the top bar",
		r.pan_dx == 0 and r.pan_dy == 0)
	r = t:update({}, zones)
	check("no tap from the top bar either", r.tap_x == nil)

	local c = gestures.new()
	c:update({ { x = 360, y = 1000 } }, zones)
	r = c:update({ { x = 400, y = 1010 } }, zones)
	check("no pan from a drag starting on a floating card",
		r.pan_dx == 0 and r.pan_dy == 0)

	-- ...and the map between them still works.
	local m = gestures.new()
	m:update({ { x = 360, y = 600 } }, zones)
	r = m:update({ { x = 400, y = 640 } }, zones)
	check("the map between the chrome still pans", r.pan_dx == 40 and r.pan_dy == 40)

	local k = gestures.new()
	k:update({ { x = 360, y = 600 } }, zones)
	k:update({ { x = 362, y = 601 } }, zones)
	r = k:update({}, zones)
	check("and a tap on the map still registers", r.tap_x ~= nil)

	-- The recogniser reports whether it declined, so the caller can decline the
	-- input too. Consuming a touch the camera did not act on left the HUD's own
	-- controls dead whenever the camera won the input-focus race.
	local f = gestures.new()
	local r0 = f:update({ { x = 500, y = 50 } }, zones)
	check("a gesture starting on the chrome is reported as blocked", r0.blocked)
	r0 = f:update({ { x = 520, y = 60 } }, zones)
	check("and stays blocked for the rest of it", r0.blocked)
	local u = gestures.new()
	local r1 = u:update({ { x = 360, y = 700 } }, zones)
	check("a gesture on the map is not blocked", not r1.blocked)

	-- A gesture that begins on the map and wanders under the bar keeps panning:
	-- it is where a drag *starts* that decides, or the map would stick every
	-- time a finger crossed the controls.
	local w = gestures.new()
	w:update({ { x = 360, y = 400 } }, zones)
	r = w:update({ { x = 360, y = 100 } }, zones)
	check("a drag that starts on the map is not cut off by the bar",
		r.pan_dy == -300)
end

print(failures == 0 and "\nALL GESTURE TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
