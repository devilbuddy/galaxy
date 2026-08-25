--- The interface kit: tokens, primitives and Druid-wired components.
--
-- Screens here are built in code rather than laid out in `.gui` files. Their
-- content is dynamic - a list of games, a list of turn events, a research tree -
-- so most of it would be script-created anyway, and an empty `.gui` beats
-- maintaining a large protobuf document alongside the code that drives it.
--
-- What this module is for is making that code *look* like one product. Every
-- screen composes from the same handful of things below, so a change to the
-- corner radius, the type scale or the card colour happens once. Anything
-- interactive is a real Druid component, which is what gives buttons their
-- press states, scrolling its inertia, and input a single owner.
--
-- Three conventions hold everywhere:
--
--   * Positions are the **top-left corner** and y grows *upward* (Defold GUI).
--     A screen is laid out by starting at the top and subtracting.
--   * Panels are 9-slices of one generated rounded rectangle
--     (tools/make_ui_textures.py) tinted by the node colour, so there is one
--     radius in the product and no per-shape artwork.
--   * Text sizes are in **pixels of the design resolution**. The fonts are
--     distance fields baked at FONT_BASE, so a size is a scale factor and any
--     size stays crisp.

local store = require("main.store")
local races = require("galaxy.sim.races")

local M = {}

-- Palette ---------------------------------------------------------------------
--
-- A near-black ground with cards a few percent lighter, which is what makes a
-- dark interface read as layered rather than as one flat sheet. Text comes in
-- exactly three weights of emphasis; using a fourth is how dark UIs turn to mud.

local function rgb(hex, alpha)
	return vmath.vector4(
		math.floor(hex / 65536) % 256 / 255,
		math.floor(hex / 256) % 256 / 255,
		hex % 256 / 255,
		alpha or 1.0)
end

M.rgb = rgb

M.BG          = rgb(0x060A12)  -- the page
M.BG_SOFT     = rgb(0x0A1020)  -- a slightly lifted region of it
M.CARD        = rgb(0x0E1626)  -- a surface holding content
M.CARD_ALT    = rgb(0x141F35)  -- a row inside a card, or a pressed card
M.CARD_HI     = rgb(0x1B2842)  -- hover / selected
M.BORDER      = rgb(0x1E2B45)  -- 1px card edge
M.BORDER_HI   = rgb(0x3A5480)  -- edge of something selected

M.TEXT        = rgb(0xDCE4F2)  -- primary
M.DIM         = rgb(0x8494AF)  -- secondary
M.FAINT       = rgb(0x4E5C76)  -- tertiary, and disabled

M.ACCENT      = rgb(0x4A7DFF)  -- the one interactive colour
M.ACCENT_TEXT = rgb(0xF2F6FF)
M.ACCENT_SOFT = rgb(0x1B2C55)  -- accent at card weight, for fills behind text
M.GOOD        = rgb(0x43D17A)
M.WARN        = rgb(0xFFB648)
M.BAD         = rgb(0xFF5F56)
M.CLEAR       = vmath.vector4(0, 0, 0, 0)

-- One colour per resource, used everywhere the three appear so the mapping is
-- learned once: warm for metal, cyan for fuel, violet for research.
M.RESOURCE_COLOUR = {
	metal    = rgb(0xE8B464),
	fuel     = rgb(0x5AD1E0),
	research = rgb(0xA78BFA),
}
M.RESOURCE_ICON = {
	metal = "icon_metal", fuel = "icon_fuel", research = "icon_research",
}
M.RESOURCE_LABEL = { metal = "Metal", fuel = "Fuel", research = "Research" }

-- Type and metrics ------------------------------------------------------------

M.ATLAS = "ui"
-- Its own atlas, not a page of the interface one: forty 128px portraits would
-- dominate a sheet that is otherwise glyphs and two panel shapes, and they are
-- third-party art with a different provenance (main/assets/portraits/CREDITS.txt).
M.PORTRAIT_ATLAS = "portraits"
M.FONT = "ui"
M.FONT_BOLD = "ui_bold"
-- The size the distance-field fonts are baked at; every text size divides by it.
-- Large enough that H1 is a scale *down*, which keeps the biggest type sharp.
local FONT_BASE = 44

-- Sizes are in design units, and a design unit is much smaller than it looks.
-- The design space is 720 units wide; a typical phone is 411 dp wide, so one
-- unit is about **0.57 dp** and a number here has to be roughly 1.75x what it
-- would be in dp. The first pass at this interface used dp-sized numbers and
-- everything came out at about 10 dp - technically legible, impossible to hit.
--
-- Floors worth keeping: body text at 15 dp (26 units) and tap targets at 48 dp
-- (84 units).
M.H1 = 48         -- 27 dp
M.H2 = 34         -- 19 dp
M.TITLE = 30      -- 17 dp
M.BODY = 26       -- 15 dp
M.SMALL = 21      -- 12 dp
M.CAPS = 19       -- 11 dp, upper case and letter-spaced

M.RADIUS = 24
M.PAD = 26        -- card inner padding
M.GAP = 18        -- between sibling cards
M.ROW = 108       -- a list row
M.CONTROL = 88    -- a button or input: 50 dp, above the 48 dp floor
M.EDGE = 18       -- gap between a card and the screen edge, before safe insets

-- Letter-spaced small caps are a big part of the look, but tracking is not on
-- every engine version this might be built with, so it degrades quietly.
local HAS_TRACKING = type(gui.set_tracking) == "function"

-- Primitives ------------------------------------------------------------------

-- Every node in this module is made by sprite() or text(), so recording those
-- two is enough to be able to tear a layout down again. A screen that rebuilds
-- itself - because the window resized, or because the safe-area insets finally
-- arrived - has to delete what it made first, and a GUI scene has a fixed node
-- budget, so leaking a layout is not a slow leak but a hard failure a few
-- rebuilds later.
local collector = nil

--- Record every node created until `collect(nil)`. Returns the previous
--- collector so callers can nest.
function M.collect(list)
	local previous = collector
	collector = list
	return previous
end

local function born(node)
	if collector then collector[#collector + 1] = node end
	return node
end

--- A box node showing an atlas image, positioned by its top-left corner.
function M.sprite(x, y, w, h, image, colour)
	local node = born(gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0)))
	gui.set_pivot(node, gui.PIVOT_NW)
	gui.set_texture(node, M.ATLAS)
	gui.play_flipbook(node, image)
	gui.set_color(node, colour or M.CARD)
	return node
end

--- Apply 9-slice margins, clamped to what the node can actually hold.
--
-- A margin wider than half the node leaves no middle for the slice to stretch,
-- and Defold renders the corners over each other - a 10x10 dot with a 31px
-- margin came out as a filled square. Below the clamp there is no point slicing
-- at all: the whole texture is corner, so scaling it is already correct.
local function set_slice(node, w, h, margin)
	local limit = math.floor(math.min(w, h) * 0.5) - 1
	if limit < 2 then return node end
	local m = math.min(margin, limit)
	gui.set_slice9(node, vmath.vector4(m))
	return node
end

M.set_slice = set_slice

--- A rounded rectangle. The 9-slice margins match the generated corner radius,
--- so a panel can be any size without the corners distorting.
function M.panel(x, y, w, h, colour)
	return set_slice(M.sprite(x, y, w, h, "panel", colour), w, h, M.RADIUS + 2)
end

--- A capsule: chips, badges, toggles, progress tracks.
--
-- Sliced **horizontally only**. The texture is a circle, so its corner radius is
-- its own half-size and every pixel outside the caps is transparent; slicing it
-- vertically as well stretches those transparent corners across the middle and
-- the node renders as a cross rather than a capsule. Anything as tall as it is
-- wide is a dot, and a plain scale of the circle is already exactly right.
function M.pill(x, y, w, h, colour)
	local node = M.sprite(x, y, w, h, "pill", colour)
	local m = math.min(31, math.floor(w * 0.5) - 1)
	if w > h and m >= 2 then
		gui.set_slice9(node, vmath.vector4(m, 0, m, 0))
	end
	return node
end

--- The outline that pairs with pill().
function M.pill_line(x, y, w, h, colour)
	local node = M.sprite(x, y, w, h, "pill_line", colour)
	local m = math.min(31, math.floor(w * 0.5) - 1)
	if w > h and m >= 2 then
		gui.set_slice9(node, vmath.vector4(m, 0, m, 0))
	end
	return node
end

--- A small filled circle, for status marks and legend swatches.
--- A commander's portrait. `id` is what the simulation reports (portrait_07).
--
-- Square, and drawn at whatever size the caller asks for; the source is 128px so
-- anything up to that is a downscale. Falls back to nothing rather than erroring
-- if the id is missing, because a face is decoration and a missing one must not
-- take a screen down with it.
function M.portrait(x, y, size, id, opts)
	opts = opts or {}
	local node = born(gui.new_box_node(vmath.vector3(x, y, 0),
		vmath.vector3(size, size, 0)))
	gui.set_pivot(node, gui.PIVOT_NW)
	gui.set_texture(node, M.PORTRAIT_ATLAS)
	-- Portraits are grouped by race (tools/import_portraits.py), so there is no
	-- generic first portrait to fall back to - the default race's is the
	-- stand-in, the same one galaxy/sim/commanders.lua falls back to.
	local ok = pcall(gui.play_flipbook, node, id or "portrait_terran_01")
	if not ok then pcall(gui.play_flipbook, node, "portrait_terran_01") end
	-- The ring goes on top, so it covers the mask's soft edge rather than
	-- sitting behind it and leaving a pale halo.
	if opts.ring ~= false then
		M.ring(x, y, size, opts.ring_colour or M.BORDER)
	end
	return node
end

--- A circle outline. The capsule texture is a circle when it is square, and it
--- must not be 9-sliced at that size - see the note on M.pill.
function M.ring(x, y, size, colour)
	return M.sprite(x, y, size, size, "pill_line", colour or M.BORDER)
end

function M.dot(x, y, size, colour)
	return M.sprite(x, y, size, size, "pill", colour)
end

--- The outline that pairs with panel().
function M.panel_line(x, y, w, h, colour)
	return set_slice(M.sprite(x, y, w, h, "panel_line", colour), w, h, M.RADIUS + 2)
end

--- A surface. Returns the fill and the border, because callers restyle both to
--- show selection and it is always the pair that changes.
function M.card(x, y, w, h, opts)
	opts = opts or {}
	local fill = M.panel(x, y, w, h, opts.colour or M.CARD)
	local border = M.panel_line(x, y, w, h, opts.border or M.BORDER)
	if opts.out then
		opts.out[#opts.out + 1] = fill
		opts.out[#opts.out + 1] = border
	end
	return fill, border
end

--- A hairline. Cards separate their sections with these rather than with gaps,
--- which is what keeps a tall card from reading as several.
function M.divider(x, y, w, colour)
	local node = M.sprite(x, y, w, 1, "solid", colour or M.BORDER)
	return node
end

--- A square glyph. `size` is the drawn box; the artwork is padded inside it.
function M.icon(x, y, size, image, colour)
	local node = M.sprite(x, y, size, size, image, colour or M.DIM)
	return node
end

--- A glyph on a rounded tile, which is how the mock-ups mark a list row.
function M.icon_tile(x, y, size, image, opts)
	opts = opts or {}
	local tile = M.panel(x, y, size, size, opts.background or M.CARD_ALT)
	local inset = opts.inset or math.floor(size * 0.22)
	local glyph = M.icon(x + inset, y - inset, size - inset * 2, image,
		opts.colour or M.DIM)
	return tile, glyph
end

--- A line of text. `size` is in design pixels; see FONT_BASE.
--
-- @param opts.bold        use the semibold face
-- @param opts.pivot       defaults to west (left edge, vertically centred)
-- @param opts.width       enables wrapping at this width
-- @param opts.anchor_top  for a wrapped block, treat y as its *top* edge
-- @param opts.tracking    letter spacing, as a fraction of the em
--
-- A wrapped node is centred on the whole block by default, so adding a second
-- line pushes the first one *upward*. Anywhere the text sits under something
-- else, pass anchor_top - otherwise a two-line effect sentence climbs into the
-- heading above it, which is exactly what happened on the research cards.
function M.text(x, y, value, size, colour, opts)
	opts = opts or {}
	size = size or M.BODY
	local node = born(gui.new_text_node(vmath.vector3(x, y, 0), value or ""))
	gui.set_font(node, opts.bold and M.FONT_BOLD or M.FONT)
	local scale = size / FONT_BASE
	gui.set_scale(node, vmath.vector3(scale, scale, 1))
	gui.set_color(node, colour or M.TEXT)
	local pivot = opts.pivot
	if not pivot then
		pivot = (opts.width and opts.anchor_top) and gui.PIVOT_NW or gui.PIVOT_W
	end
	gui.set_pivot(node, pivot)
	if opts.width then
		gui.set_line_break(node, true)
		-- Size is in the node's own units, so it has to be divided back out of
		-- the scale or a wrapped block breaks at the wrong column.
		gui.set_size(node, vmath.vector3(opts.width / scale, (opts.height or 400) / scale, 0))
	end
	if opts.tracking and HAS_TRACKING then
		gui.set_tracking(node, opts.tracking)
	end
	return node
end

function M.h1(x, y, value, colour)
	return M.text(x, y, value, M.H1, colour or M.TEXT, { bold = true })
end

function M.h2(x, y, value, colour)
	return M.text(x, y, value, M.H2, colour or M.TEXT, { bold = true })
end

function M.title(x, y, value, colour)
	return M.text(x, y, value, M.TITLE, colour or M.TEXT, { bold = true })
end

function M.body(x, y, value, colour, opts)
	return M.text(x, y, value, M.BODY, colour or M.TEXT, opts)
end

function M.small(x, y, value, colour, opts)
	return M.text(x, y, value, M.SMALL, colour or M.DIM, opts)
end

--- A letter-spaced upper-case label. Section headings and field names.
function M.caps(x, y, value, colour)
	return M.text(x, y, (value or ""):upper(), M.CAPS, colour or M.FAINT,
		{ bold = true, tracking = 0.12 })
end

--- Right-aligned text, for the value column of a row.
function M.value(x, y, value, size, colour, opts)
	opts = opts or {}
	opts.pivot = gui.PIVOT_E
	opts.bold = opts.bold ~= false
	return M.text(x, y, value, size or M.TITLE, colour or M.TEXT, opts)
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

--- Reparent a batch of nodes, so a composite built at the top level can be
--- dropped into a scroll's content afterwards.
function M.adopt(parent, ...)
	local nodes = { ... }
	for i = 1, #nodes do
		if nodes[i] then gui.set_parent(nodes[i], parent) end
	end
	return ...
end

-- Composites ------------------------------------------------------------------

--- A card's section heading, optionally with a count badge on the right.
-- Returns the y of the first content line beneath it.
function M.section(x, y, w, title, count, out)
	local function keep(node)
		if out then out[#out + 1] = node end
		return node
	end
	keep(M.caps(x, y - 13, title))
	if count then
		local label = tostring(count)
		local bw = 34 + #label * 12
		keep(M.pill(x + w - bw, y, bw, 36, M.CARD_ALT))
		keep(M.text(x + w - bw * 0.5, y - 18, label, M.SMALL, M.DIM,
			{ pivot = gui.PIVOT_CENTER, bold = true }))
	end
	return y - 46
end

--- One resource: glyph, name, balance, and the rate underneath it.
--
-- The rate is the number players actually steer by - a balance only says where
-- you are - so it is always shown, and coloured by sign rather than by resource.
function M.resource_row(x, y, w, kind, balance, rate, out)
	local function keep(node)
		if out then out[#out + 1] = node end
		return node
	end
	local colour = M.RESOURCE_COLOUR[kind] or M.TEXT
	local tile_size = 60
	-- icon_tile returns two nodes; keeping only the first would leak the glyph
	-- on the next rebuild.
	local tile, glyph = M.icon_tile(x, y - 8, tile_size, M.RESOURCE_ICON[kind], {
		background = M.CARD_ALT, colour = colour,
	})
	keep(tile)
	keep(glyph)
	keep(M.body(x + tile_size + 18, y - 38, M.RESOURCE_LABEL[kind] or kind, M.TEXT))
	keep(M.value(x + w, y - 29, M.number(balance), M.H2, M.TEXT))
	if rate ~= nil then
		keep(M.value(x + w, y - 62, M.rate(rate) .. " / turn", M.SMALL,
			rate >= 0 and M.GOOD or M.BAD, { bold = false }))
	end
	return y - 88
end

--- A compact glyph-and-number chip, for the always-visible overview bar.
-- Returns the node list and the width it consumed.
function M.chip(x, y, kind, value, out)
	local function keep(node)
		if out then out[#out + 1] = node end
		return node
	end
	local colour = M.RESOURCE_COLOUR[kind] or M.TEXT
	local text = M.number(value)
	local icon_size = 36
	local w = icon_size + 10 + M.text_width(text, M.BODY) + 6
	keep(M.icon(x, y, icon_size, M.RESOURCE_ICON[kind], colour))
	local label = keep(M.text(x + icon_size + 8, y - icon_size * 0.5, text,
		M.BODY, M.TEXT, { bold = true }))
	return label, w
end

--- A two-line list row: tile, title, subtitle, and an optional right accessory.
function M.list_row(x, y, w, opts, out)
	local function keep(node)
		if out then out[#out + 1] = node end
		return node
	end
	local h = opts.height or M.ROW
	local pad = 18
	local text_x = x + pad
	if opts.icon then
		local size = 62
		local tile, glyph = M.icon_tile(x + pad, y - (h - size) * 0.5, size, opts.icon, {
			background = opts.icon_background or M.CARD_ALT,
			colour = opts.icon_colour or M.DIM,
		})
		keep(tile)
		keep(glyph)
		text_x = x + pad + size + 18
	end
	if opts.subtitle then
		keep(M.body(text_x, y - h * 0.5 + 16, opts.title, opts.title_colour or M.TEXT))
		keep(M.small(text_x, y - h * 0.5 - 17, opts.subtitle, opts.subtitle_colour or M.DIM))
	else
		keep(M.body(text_x, y - h * 0.5, opts.title, opts.title_colour or M.TEXT))
	end
	if opts.accessory then
		keep(M.value(x + w - pad, y - h * 0.5, opts.accessory,
			opts.accessory_size or M.BODY, opts.accessory_colour or M.DIM))
	end
	if opts.dot then
		keep(M.dot(x + w - pad - 14, y - h * 0.5 + 7, 14, opts.dot))
	end
	return y - h
end

--- A thin progress track. Returns the fill node so a caller can animate it, and
--- registers a Druid progress component when a druid instance is supplied.
function M.progress(druid, x, y, w, fraction, colour, opts)
	opts = opts or {}
	local h = opts.height or 9
	local track = M.pill(x, y, w, h, opts.track or M.CARD_ALT)
	local fill = M.pill(x, y, w, h, colour or M.ACCENT)
	local clamped = math.max(0, math.min(1, fraction or 0))
	local component = nil
	if druid then
		component = druid:new_progress(fill, "x", clamped)
	else
		gui.set_size(fill, vmath.vector3(w * clamped, h, 0))
	end
	return track, fill, component
end

-- Interactive -----------------------------------------------------------------

local BUTTON_STYLE = {
	primary   = { fill = M.ACCENT,     border = M.ACCENT,   text = M.ACCENT_TEXT },
	secondary = { fill = M.CARD_ALT,   border = M.BORDER,   text = M.TEXT },
	ghost     = { fill = M.CLEAR,      border = M.BORDER,   text = M.DIM },
	danger    = { fill = M.CARD_ALT,   border = M.BORDER,   text = M.BAD },
	disabled  = { fill = M.BG_SOFT,    border = M.BORDER,   text = M.FAINT },
	-- For the moment after an action landed. Not interactive - it is a receipt,
	-- and it reverts to whatever the button says at rest.
	success   = { fill = M.GOOD,       border = M.GOOD,     text = M.BG },
}

--- A button, as a real Druid component.
--
-- Druid supplies the press animation and the input plumbing; the only thing
-- this adds is the skin, and a handle to restyle it later. Callers get back a
-- table rather than loose nodes because a button is nearly always something a
-- screen enables, disables or relabels after the fact.
function M.button(druid, x, y, w, h, caption, on_click, opts)
	opts = opts or {}
	local style = BUTTON_STYLE[opts.style or "secondary"]
	local shape = opts.pill and M.pill or M.panel
	local fill = shape(x, y, w, h, style.fill)
	local border = opts.pill and M.pill_line(x, y, w, h, style.border)
		or M.panel_line(x, y, w, h, style.border)

	local text_x = x + w * 0.5
	local glyph = nil
	if opts.icon then
		local size = opts.icon_size or 32
		-- Glyph and caption are centred as a pair, not each in the middle.
		local caption_w = M.text_width(caption, opts.size or M.BODY)
		local total = size + 12 + caption_w
		glyph = M.icon(x + (w - total) * 0.5, y - (h - size) * 0.5, size,
			opts.icon, style.text)
		text_x = x + (w - total) * 0.5 + size + 12 + caption_w * 0.5
	end
	local label = M.text(text_x, y - h * 0.5, caption or "", opts.size or M.BODY,
		style.text, { bold = true, pivot = gui.PIVOT_CENTER })

	local handle = {
		fill = fill, border = border, label = label, glyph = glyph,
		component = druid and druid:new_button(fill, on_click) or nil,
	}

	--- Restyle in place. `nil` style means "keep the current one".
	function handle.set_style(name)
		local s = BUTTON_STYLE[name] or BUTTON_STYLE.secondary
		gui.set_color(fill, s.fill)
		gui.set_color(border, s.border)
		gui.set_color(label, s.text)
		if glyph then gui.set_color(glyph, s.text) end
	end

	function handle.set_enabled(enabled)
		if handle.component then handle.component:set_enabled(enabled) end
		handle.set_style(enabled and (opts.style or "secondary") or "disabled")
	end

	function handle.set_text(value)
		gui.set_text(label, value or "")
	end

	function handle.set_visible(visible)
		gui.set_enabled(fill, visible)
		gui.set_enabled(border, visible)
		gui.set_enabled(label, visible)
		if glyph then gui.set_enabled(glyph, visible) end
	end

	return handle
end

--- A square glyph-only button, for close and back.
function M.icon_button(druid, x, y, size, image, on_click, opts)
	opts = opts or {}
	local background = opts.background or M.CARD_ALT
	local colour = opts.colour or M.DIM
	local fill = M.panel(x, y, size, size, background)
	local inset = math.floor(size * 0.28)
	local glyph = M.icon(x + inset, y - inset, size - inset * 2, image, colour)

	local handle = {
		fill = fill, glyph = glyph,
		component = druid and druid:new_button(fill, on_click) or nil,
	}

	--- Grey it out and stop it responding, together.
	--
	-- A glyph button has no caption to change, so the tint is the only thing
	-- saying whether it will do anything - and a control that still animates a
	-- press but does nothing is indistinguishable from a broken one.
	function handle.set_enabled(enabled)
		if handle.component then handle.component:set_enabled(enabled) end
		gui.set_color(fill, enabled and background or M.CARD)
		gui.set_color(glyph, enabled and colour or M.FAINT)
	end

	return handle
end

--- A row of text tabs with an underline under the active one.
--
-- @param items array of { id =, label = }
-- @param on_pick function(id)
-- @return a handle with set_active(id)
function M.tabs(druid, x, y, w, items, active, on_pick)
	local labels, marks = {}, {}
	local components = {}
	local column = w / #items
	for i = 1, #items do
		local cx = x + column * (i - 1)
		-- The hit target is the whole column, and invisible: a tab strip that
		-- only responds to the glyphs themselves is unusable on a phone.
		local target = M.sprite(cx, y, column, 66, "solid", M.CLEAR)
		labels[i] = M.text(cx + column * 0.5, y - 28, items[i].label:upper(), M.CAPS,
			M.DIM, { bold = true, pivot = gui.PIVOT_CENTER, tracking = 0.10 })
		marks[i] = M.sprite(cx + column * 0.12, y - 60, column * 0.76, 3, "solid", M.CLEAR)
		if druid then
			components[#components + 1] = druid:new_button(target, function()
				if on_pick then on_pick(items[i].id) end
			end)
		end
	end

	-- Handed back so a caller that rebuilds a region can take them out again.
	-- Without this they outlived their nodes and Druid went on polling deleted
	-- ones - `hover.lua: Deleted node` on the next touch anywhere.
	local handle = { components = components }
	function handle.set_active(id)
		for i = 1, #items do
			local on = items[i].id == id
			gui.set_color(labels[i], on and M.TEXT or M.DIM)
			gui.set_color(marks[i], on and M.ACCENT or M.CLEAR)
		end
	end
	handle.set_active(active or items[1].id)
	return handle
end

--- A clipped scrolling region. Returns the view node, the content node to
--- parent rows into, and the Druid scroll so content height can be updated.
function M.scroll(druid, x, y, w, h)
	local view = M.sprite(x, y, w, h, "solid", M.CLEAR)
	gui.set_clipping_mode(view, gui.CLIPPING_MODE_STENCIL)
	local content = M.sprite(0, 0, w, h, "solid", M.CLEAR)
	gui.set_parent(content, view)
	gui.set_position(content, vmath.vector3(0, 0, 0))
	local scroll = druid and druid:new_scroll(view, content) or nil
	return view, content, scroll
end

--- Resize a scroll's content to whatever was actually laid out.
--
-- Without this the list either cannot reach its end or scrolls into empty
-- space, and which one depends on the data - so it is easy to ship broken.
function M.fit_scroll(scroll, content, w, used_height, view_height)
	local h = math.max(view_height or 0, used_height)
	gui.set_size(content, vmath.vector3(w, h, 0))
	if scroll then scroll:set_size(vmath.vector3(w, h, 0)) end
end

--- A full-screen ground behind a popup.
--
-- Opaque by default. A translucent one let the map HUD read through and collide
-- with the popup's own heading, and these popups replace the whole screen
-- anyway rather than framing what is behind them.
--
-- Deliberately *not* a Druid blocker. A blocker covering the whole screen also
-- sits in front of the popup's own scroll regions and eats their drags, so the
-- research tree could not be scrolled at all. Keeping input away from the map
-- behind is the modal's job: see M.modal_input.
function M.shade(alpha)
	local s = store.screen
	return M.sprite(0, s.height, s.width, s.height, "solid",
		vmath.vector4(0.024, 0.039, 0.071, alpha or 1.0))
end

--- Input handling for a full-screen popup.
--
-- Always claims the action, whether or not a component here used it: the map and
-- its camera are a separate scene that would otherwise pan and select underneath
-- the popup.
--
-- Takes one Druid instance or a list of them, because a screen that rebuilds
-- part of itself wants a separate instance for that part - see M.region.
function M.modal_input(druid, action_id, action)
	local converted = M.gui_action(action)
	if druid[1] ~= nil or druid.on_input == nil then
		for i = 1, #druid do
			if druid[i] then druid[i]:on_input(action_id, converted) end
		end
	else
		druid:on_input(action_id, converted)
	end
	return true
end

--- Tear down a rebuildable region: its Druid instance, then its nodes.
--
-- The order is the point. A component whose node has already been deleted throws
-- from its own teardown, and one that outlives its node throws on the next touch
-- anywhere on screen. Giving a region its own instance makes both impossible
-- without anybody having to remember to track every component they created -
-- which is exactly what went wrong: `ui.tabs` and `ui.scroll` each quietly
-- registered one and the caller only tracked its buttons.
function M.region(instance, nodes)
	if instance then instance:final() end
	if nodes then
		for i = 1, #nodes do
			if nodes[i] then gui.delete_node(nodes[i]) end
		end
		for i = #nodes, 1, -1 do nodes[i] = nil end
	end
end

-- Formatting ------------------------------------------------------------------

--- Compact integer: 940, 1.2k, 18k. Long numbers push a narrow row's other
--- columns off the edge, and the exact value is never the point.
function M.number(n)
	n = math.floor(tonumber(n) or 0)
	local sign = n < 0 and "-" or ""
	n = math.abs(n)
	-- Abbreviated only past ten thousand. At the old threshold two research
	-- costs a hundred apart rendered as "960" and "1.0k", which is the same
	-- quantity described two ways in one view - and the game's numbers cluster
	-- exactly there.
	if n < 10000 then return sign .. tostring(n) end
	if n < 1000000 then return sign .. string.format("%dk", math.floor(n / 1000)) end
	return sign .. string.format("%.1fM", n / 1000000)
end

--- "1 ship" / "2 ships". Enough English to keep a log from reading like a
--- debug dump; anything irregular passes its own plural.
function M.plural(n, singular, plural)
	n = math.floor(tonumber(n) or 0)
	return n .. " " .. (n == 1 and singular or (plural or (singular .. "s")))
end

--- A signed rate, for an income figure shown next to a balance.
function M.rate(n)
	n = math.floor(tonumber(n) or 0)
	return (n >= 0 and "+" or "") .. M.number(n)
end

--- Seconds as a short human duration: "4h 12m", "45s".
function M.duration(seconds)
	seconds = math.floor(seconds or 0)
	if seconds <= 0 then return "now" end
	if seconds < 60 then return seconds .. "s" end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then return minutes .. "m" end
	local hours = math.floor(minutes / 60)
	if hours < 24 then return string.format("%dh %02dm", hours, minutes % 60) end
	return string.format("%dd %dh", math.floor(hours / 24), hours % 24)
end

--- Estimated rendered width. An average advance, not an exact figure; fine for
--- centring an icon-and-caption pair, which is all it is used for.
function M.text_width(value, size)
	return #(value or "") * (size or M.BODY) * 0.56
end

-- Measured widths, keyed by font and string. Map labels are a fixed set of star
-- and region names, so after the first frame every lookup is a cache hit.
local measured = {}

--- Exact rendered width of a string, in the units a node scaled to `scale`
--- would occupy.
--
-- The estimate above is not good enough here: an average advance under-measures
-- upper-case badly, and region names are upper case. Labels overlapped each
-- other and ran off the screen edge because the rejection test thought they
-- were narrower than they are.
function M.measure(font, value, scale)
	if not value or value == "" then return 0 end
	local per_font = measured[font]
	if not per_font then
		per_font = {}
		measured[font] = per_font
	end
	local w = per_font[value]
	if not w then
		local ok, metrics = pcall(gui.get_text_metrics, font, value)
		w = (ok and metrics and metrics.width) or (#value * 20)
		per_font[value] = w
	end
	return w * (scale or 1)
end

--- A race's identity colour, as declared in galaxy/sim/races.lua.
function M.race_colour(id, alpha)
	local c = races.by_id(id).colour
	return vmath.vector4(c[1], c[2], c[3], alpha or 1.0)
end

--- A race's display name, tolerating an id the client has never heard of.
function M.race_label(id)
	return races.by_id(id).label
end

--- Black or white, whichever is legible on `colour`.
--
-- The race colours span a wide luminance range, and picking one fixed text
-- colour for a selected chip made half of them unreadable.
function M.contrast_text(colour)
	local luminance = 0.2126 * colour.x + 0.7152 * colour.y + 0.0722 * colour.z
	if luminance > 0.55 then return rgb(0x0A0E18) end
	return rgb(0xF4F7FF)
end

--- The margin a screen should use against each edge: the design gap plus
--- whatever the device's notch, home indicator or gesture strip needs.
--
-- The world still draws edge to edge - the extension runs in custom mode, so
-- there are no letterbox bars - and only chrome is inset. See main/safearea.lua.
function M.inset(extra)
	local s = store.safe or { top = 0, bottom = 0, left = 0, right = 0 }
	local e = (extra or 0) + M.EDGE
	return {
		top = e + s.top,
		bottom = e + s.bottom,
		left = e + s.left,
		right = e + s.right,
	}
end

-- Input -----------------------------------------------------------------------

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

M.node_bounds = node_bounds

--- Convert an input action into the coordinate space GUI nodes live in.
--
-- Defold normalises touches to the *configured* display size (720x1280), but
-- this project derives the view height from the real aspect ratio, so GUI nodes
-- sit in a 720x1560-ish space on a tall phone. Druid hit-tests with whatever
-- action it is handed, so an unconverted action misses by an amount that grows
-- with height: a button near the bottom of the screen still works and one near
-- the top is unreachable, which is a particularly confusing way for a UI to
-- fail.
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

return M
