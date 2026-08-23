--- Small helpers for building screens in code.
--
-- The screens here are built at runtime rather than laid out in .gui files.
-- Their content is dynamic (a list of games, a list of turn events), so most of
-- it would have to be created in script anyway, and keeping the .gui files
-- empty avoids maintaining a large protobuf document alongside the code that
-- drives it. Druid supplies the interaction; this just standardises the look.

local store = require("main.store")

local M = {}

M.BACKGROUND = vmath.vector4(0.026, 0.030, 0.055, 1.0)
M.PANEL = vmath.vector4(0.07, 0.09, 0.15, 0.95)
M.PANEL_ALT = vmath.vector4(0.10, 0.13, 0.21, 0.95)
M.ACCENT = vmath.vector4(0.16, 0.24, 0.42, 1.0)
M.ACCENT_TEXT = vmath.vector4(0.82, 0.88, 1.0, 1.0)
M.TEXT = vmath.vector4(0.80, 0.85, 0.95, 1.0)
M.DIM = vmath.vector4(0.48, 0.54, 0.68, 1.0)
M.GOOD = vmath.vector4(0.45, 0.85, 0.55, 1.0)
M.BAD = vmath.vector4(0.95, 0.45, 0.40, 1.0)

M.FONT = "map"

--- A solid rectangle, positioned by its top-left corner.
function M.panel(x, y, w, h, colour)
	local node = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0))
	gui.set_pivot(node, gui.PIVOT_NW)
	gui.set_color(node, colour or M.PANEL)
	return node
end

--- A line of text, positioned by its left edge at the given baseline.
function M.label(x, y, value, scale, colour, pivot)
	local node = gui.new_text_node(vmath.vector3(x, y, 0), value or "")
	gui.set_font(node, M.FONT)
	gui.set_scale(node, vmath.vector3(scale or 0.8, scale or 0.8, 1))
	gui.set_color(node, colour or M.TEXT)
	gui.set_pivot(node, pivot or gui.PIVOT_W)
	return node
end

--- A button: a panel with a centred caption. Returns both nodes so the caller
--- can restyle or relabel it later.
function M.button(x, y, w, h, caption, scale)
	local box = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0))
	gui.set_pivot(box, gui.PIVOT_NW)
	gui.set_color(box, M.ACCENT)

	local text = gui.new_text_node(vmath.vector3(x + w * 0.5, y - h * 0.5, 0), caption)
	gui.set_font(text, M.FONT)
	gui.set_scale(text, vmath.vector3(scale or 0.8, scale or 0.8, 1))
	gui.set_pivot(text, gui.PIVOT_CENTER)
	gui.set_color(text, M.ACCENT_TEXT)
	return box, text
end

--- Enable/disable styling for a button built by M.button.
function M.set_button_enabled(box, text, enabled)
	gui.set_color(box, enabled and M.ACCENT or M.PANEL_ALT)
	gui.set_color(text, enabled and M.ACCENT_TEXT or M.DIM)
end

--- Delete a list of nodes and empty the list. Screens rebuild their dynamic
--- sections wholesale rather than diffing, which at these sizes is simpler and
--- fast enough.
function M.clear(nodes)
	for i = 1, #nodes do
		if nodes[i] then gui.delete_node(nodes[i]) end
	end
	for i = #nodes, 1, -1 do nodes[i] = nil end
end

-- Pivot -> fraction of (width, height) to subtract from the node's position to
-- reach its lower-left corner. Defold GUI y increases upwards.
local PIVOT_OFFSET

--- Axis-aligned bounds of a node, in this project's GUI layout space.
local function node_bounds(node)
	local x, y = 0, 0
	local n = node
	while n do
		local p = gui.get_position(n)
		x = x + p.x
		y = y + p.y
		n = gui.get_parent(n)
	end

	local size = gui.get_size(node)
	local scale = gui.get_scale(node)
	local w, h = size.x * scale.x, size.y * scale.y

	local offset = PIVOT_OFFSET[gui.get_pivot(node)] or PIVOT_OFFSET[gui.PIVOT_CENTER]
	local x0 = x + offset[1] * w
	local y0 = y + offset[2] * h
	return x0, y0, x0 + w, y0 + h
end

--- Replace Druid's hit-testing with one that works in our layout space.
--
-- Druid asks `gui.pick_node`, which resolves screen coordinates against the
-- *configured* display resolution (720x1280). This project lays GUI out in a
-- view space whose height is derived from the device's real aspect ratio - on a
-- 19.5:9 phone that is 720x1560 - so any node above y=1280 is unpickable no
-- matter what coordinates are supplied. Buttons near the bottom worked and
-- buttons near the top silently did nothing.
--
-- Every node here is created in code with a known position, size and pivot, so
-- an axis-aligned test against those is exact, and it is unaffected by whatever
-- assumptions the built-in picking makes.
function M.install_druid_picking()
	if M._picking_installed then return end
	PIVOT_OFFSET = {
		[gui.PIVOT_CENTER] = { -0.5, -0.5 },
		[gui.PIVOT_N] = { -0.5, -1.0 },
		[gui.PIVOT_NE] = { -1.0, -1.0 },
		[gui.PIVOT_E] = { -1.0, -0.5 },
		[gui.PIVOT_SE] = { -1.0, 0.0 },
		[gui.PIVOT_S] = { -0.5, 0.0 },
		[gui.PIVOT_SW] = { 0.0, 0.0 },
		[gui.PIVOT_W] = { 0.0, -0.5 },
		[gui.PIVOT_NW] = { 0.0, -1.0 },
	}

	local helper = require("druid.helper")
	helper.pick_node = function(node, x, y, click_zone)
		local x0, y0, x1, y1 = node_bounds(node)
		local hit = x >= x0 and x <= x1 and y >= y0 and y <= y1
		if hit and click_zone then
			local cx0, cy0, cx1, cy1 = node_bounds(click_zone)
			hit = x >= cx0 and x <= cx1 and y >= cy0 and y <= cy1
		end
		return hit
	end
	M._picking_installed = true
end

--- Convert an input action into the coordinate space GUI nodes live in.
--
-- Defold normalises touches to the *configured* display size (720x1280), but
-- this project derives the view height from the real aspect ratio, so GUI nodes
-- sit in a 720x1560-ish space on a tall phone. Druid hit-tests with
-- gui.pick_node using whatever action it is handed, so an unconverted action
-- misses by an amount that grows with height: a button near the bottom of the
-- screen still works and one near the top is unreachable, which is a
-- particularly confusing way for a UI to fail.
--
-- Returns a copy: the same action table is dispatched to other listeners, and
-- scaling it in place would make them convert twice.
function M.gui_action(action)
	if not action then return action end
	local s = store.screen
	local sx, sy = s.input_scale_x or 1, s.input_scale_y or 1
	if sx == 1 and sy == 1 then return action end

	local out = {}
	for k, v in pairs(action) do out[k] = v end
	if action.x then out.x = action.x * sx end
	if action.y then out.y = action.y * sy end
	if action.dx then out.dx = action.dx * sx end
	if action.dy then out.dy = action.dy * sy end
	if action.screen_x then out.screen_x = action.screen_x * sx end
	if action.screen_y then out.screen_y = action.screen_y * sy end

	if action.touch then
		local touches = {}
		for i = 1, #action.touch do
			local t = action.touch[i]
			local copy = {}
			for k, v in pairs(t) do copy[k] = v end
			copy.x = t.x * sx
			copy.y = t.y * sy
			if t.dx then copy.dx = t.dx * sx end
			if t.dy then copy.dy = t.dy * sy end
			touches[i] = copy
		end
		out.touch = touches
	end
	return out
end

--- Seconds as a short human duration: "4h 12m", "45s".
function M.duration(seconds)
	seconds = math.floor(seconds or 0)
	if seconds <= 0 then return "now" end
	if seconds < 60 then return seconds .. "s" end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then return minutes .. "m" end
	local hours = math.floor(minutes / 60)
	return string.format("%dh %02dm", hours, minutes % 60)
end

return M
