--- The hex lattice: axial coordinates, neighbours, and where a cell sits.
--
-- **Flat-top hexagons**, in axial coordinates `(q, r)`. Flat-top rather than
-- pointy-top because that is how the art is drawn: a tile is 238x207, which is
-- exactly the bounding box of a flat-top hexagon of size 119 (`2s` wide by
-- `sqrt(3)*s` tall, = 238 x 206.1). Every layout number below follows from that
-- one measurement, so the sprites tessellate with no gaps and no overlap.
--
--     x = size * 1.5 * q
--     y = size * sqrt(3) * (r + q/2)
--
-- The `q/2` term is the column stagger: neighbouring columns sit half a row
-- apart, which is what makes a flat-top grid interlock.
--
-- Engine-free like the rest of `galaxy/`, and deliberately arithmetic-only - no
-- `exp`, `log` or `atan2` anywhere. Those are not required to be correctly
-- rounded and macOS, glibc and Android's bionic can disagree in the last bit,
-- which is why the old density field had to be quantised to a coarse ladder
-- before it could be trusted. A lattice needs none of that: integer coordinates
-- in, exact multiplication out, identical on every target.

local M = {}

local sqrt, abs, floor, max, min = math.sqrt, math.abs, math.floor, math.max, math.min

-- sqrt(3), the vertical pitch of a flat-top grid in units of `size`. Named
-- because it appears in the layout and in the tests, and a literal 1.7320508
-- in two places is two chances to mistype it.
M.SQRT3 = sqrt(3)

-- The six neighbours, in a fixed order. **The order is load-bearing**: it is
-- what `galaxy.graph` walks to build the adjacency list, so reordering it
-- reorders every adjacency array and moves every seed's digest. Starting east
-- and turning anticlockwise.
M.DIRECTIONS = {
	{ 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, 0 }, { -1, 1 }, { 0, 1 },
}

--- A cell's centre in world units.
function M.to_world(q, r, size)
	return size * 1.5 * q, size * M.SQRT3 * (r + q * 0.5)
end

--- Lattice distance in whole steps: how many hexes a commander must cross.
--
-- Axial distance is the cube distance of the same cell, and `s = -q - r`, so
-- this is `(|q| + |r| + |q + r|) / 2` without ever building the third axis.
function M.distance(aq, ar, bq, br)
	local dq, dr = aq - bq, ar - br
	return (abs(dq) + abs(dr) + abs(dq + dr)) * 0.5
end

--- A stable key for a cell, for the sparse tables the generator builds with.
--
-- **The key must stay small.** It is a single integer folding `(q, r)`, and the
-- obvious encoding - a generous offset and a stride to match - produces values
-- in the tens of millions. On LuaJIT that is free: a sparse integer key lands in
-- the hash part like any other. On gopher-lua it is not, and a table keyed that
-- way took Nakama out with an OOM before it could answer a single request. The
-- symptom is brutal to read: the container simply disappears, the client sees a
-- closed socket, and nothing is logged anywhere because nothing got far enough
-- to log it.
--
-- So the offset is sized to the largest field the game will ever build rather
-- than to a comfortable-looking round number. `MAX_COORD` of 64 covers a field
-- of radius 63 - which would hold 12,097 cells against the 220 the game uses -
-- and caps the key at 16,640, small enough that it does not matter which half of
-- a table it lands in on either runtime.
--
-- Still an integer rather than a `q .. ":" .. r` string, because these tables are
-- built and probed hundreds of thousands of times per generation and gopher-lua
-- pays for every concatenation. Nothing here is ever serialised - the wire
-- carries `q` and `r` themselves - so the encoding is private to one pass.
local MAX_COORD = 64
local KEY_STRIDE = 2 * MAX_COORD + 1

M.MAX_COORD = MAX_COORD

function M.key(q, r)
	return (q + MAX_COORD) * KEY_STRIDE + (r + MAX_COORD)
end

--- Every cell within `radius` of the origin, as `{ q, r }` pairs.
--
-- Returned in a fixed scan order - by column, then by row within it - so the
-- field is identical on every runtime. `pairs` order is never involved.
-- A field of radius N holds `1 + 3N(N+1)` cells.
function M.field(radius)
	-- A radius past this would wrap two different cells onto one key and the
	-- map would come out with holes in it, silently. Nothing near it is
	-- reachable in play; this is here so a future experiment fails loudly.
	assert(radius + 1 < MAX_COORD,
		"hex.field: radius " .. tostring(radius) .. " exceeds the key range")
	local cells = {}
	for q = -radius, radius do
		local lo = max(-radius, -q - radius)
		local hi = min(radius, -q + radius)
		for r = lo, hi do
			cells[#cells + 1] = { q, r }
		end
	end
	return cells
end

--- How many cells a field of this radius holds, without building it.
function M.field_size(radius)
	return 1 + 3 * radius * (radius + 1)
end

--- The bounding half-extents of a field of `radius` at `size`, in world units.
--
-- The extreme column centre is at `1.5 * radius * size` and the hex reaches a
-- further `size` past it; the extreme row centre is at `sqrt(3) * radius * size`
-- and reaches a further `sqrt(3)/2 * size`. Used to pick a world size that the
-- whole field fits inside.
function M.extent(radius, size)
	return (1.5 * radius + 1) * size, M.SQRT3 * (radius + 0.5) * size
end

--- The six corners of a cell, anticlockwise from due east, in world units.
--
-- Only the offline sketch draws these - the game hands the whole hex to a
-- sprite - but they are the definition the sprite's 238x207 quad has to match,
-- so they live here rather than in the renderer.
function M.corners(q, r, size)
	local cx, cy = M.to_world(q, r, size)
	local h = M.SQRT3 * 0.5 * size
	return {
		cx + size, cy,
		cx + size * 0.5, cy + h,
		cx - size * 0.5, cy + h,
		cx - size, cy,
		cx - size * 0.5, cy - h,
		cx + size * 0.5, cy - h,
	}
end

return M
