--- Where the land is: one continent in a sea, grown outward from its heart.
--
-- **Connectivity is a property of the construction, not a repair.** The
-- continent grows one cell at a time, and every cell it takes is adjacent to
-- something it already holds - so the land is a single connected component from
-- the first cell to the last, and there is no flood fill afterwards to check it,
-- no largest-component pass to pick a winner, and no stitching step to get
-- wrong. A player cannot be islanded because an island cannot exist.
--
-- It also lands on the requested size *exactly*. The old sampler solved for a
-- spacing that got near a target star count and accepted whatever it got; here
-- the count is the loop bound. That matters more than it sounds: habitability,
-- province size and the victory threshold are all fractions of it.
--
-- What the noise decides is only the *order* cells are taken in, which is what
-- makes the coastline ragged - the frontier advances along a noise contour
-- rather than a circle - and what leaves inland lakes behind, where a cell the
-- noise scored badly ends up surrounded by land that grew around it.
--
-- Arithmetic only: value noise (an integer hash, a lerp and a quintic
-- polynomial) plus `sqrt`, which IEEE requires to be correctly rounded. No
-- `exp`, `log` or `atan2` anywhere, so unlike the spiral density field this
-- needs no quantisation ladder to survive the difference between macOS libm,
-- glibc and Android's bionic.

local hex = require("galaxy.hex")
local noise = require("galaxy.noise")
local rng = require("galaxy.rng")

local M = {}

local sqrt, floor = math.sqrt, math.floor

-- The three numbers that decide what a coastline looks like. They were picked
-- by measuring rather than by eye - `pull` alone makes every seed the same fat
-- oval, which is what the first pass produced:
--
--   pull  amp  freq  ->  coast edges  corridor cells  mean degree
--   1.35  0.62 0.17       118            8.7            5.20   a disc
--   0.90  1.20 0.15       171            8.7            5.20
--   0.70  1.60 0.13       215           10.9            5.01
--   0.80  1.60 0.22       236           14.6            4.90   <- shipped
--
-- "corridor cells" are land with two or fewer land neighbours: the isthmuses
-- and headlands a player has to fight through. At the shipped numbers about 7%
-- of the map is one, which is texture; the first pass had almost none.

-- How fast the pull toward the middle falls off. The score is
-- `1 - (d/dmax)^2 * PULL`, so a larger number holds the coast tighter to the
-- centre and rounder; a smaller one lets the noise carry headlands to the rim.
local PULL = 0.80

-- How much the noise is allowed to override that pull. This is the whole
-- character of the coastline: at 0 the continent is a disc, and far past this
-- the noise wins outright and the result is an archipelago - which the game
-- cannot use, because there is no sea movement. It stays usable at any setting
-- because connectivity comes from the growth, not from the threshold.
local NOISE_AMP = 1.60

-- Noise frequency in units of the hex size. 0.22 puts a feature every four or
-- five hexes: a bay you can march around rather than a jagged edge.
local NOISE_FREQ = 0.22
local NOISE_OCTAVES = 5

-- Rings of sea drawn beyond the coast. It does two jobs at once:
--
--   * the continent is grown inside `inner` and the field is `inner + margin`,
--     so the coastline can never be the edge of the array. Without that the
--     growth reached the outermost ring on 18 seeds in 20 and left about four
--     land cells sitting on it - a short straight coast in an otherwise ragged
--     one, with no cause visible anywhere near the renderer.
--   * the drawn sea is trimmed to this many steps from land, so the ocean
--     follows the coastline instead of ending in a hard hexagon, and its cost
--     scales with the length of the coast rather than with the field.
local SEA_MARGIN = 2

--- Rings of sea drawn beyond the coast; the field is `inner + this`.
M.SEA_MARGIN = SEA_MARGIN

--- Grow a continent of exactly `target` cells inside a field of `radius`.
--
-- Growth is confined to `radius - RIM_MARGIN`, so the outer rings are always
-- open sea and the coast is never the field boundary.
--
-- Returns:
--   land     array of { q, r }, in the order they were claimed
--   is_land  set keyed by hex.key(q, r) -> true
--   water    array of { q, r } for every field cell that is not land
function M.build(seed, inner, target, opts)
	opts = opts or {}
	local radius = inner + SEA_MARGIN
	local pull = opts.pull or PULL
	local amp = opts.amp or NOISE_AMP
	local freq = opts.freq or NOISE_FREQ
	local octaves = opts.octaves or NOISE_OCTAVES
	local cells = hex.field(radius)
	local n = #cells
	if target > n then target = n end

	-- One derived stream, used only to seed the noise field. The noise itself
	-- is a pure function of position, so nothing here depends on the order
	-- cells happen to be visited in.
	local nseed = rng.stream(seed, "land"):u32()

	-- Score every cell once: pull toward the middle, pushed around by noise.
	-- Normalised by the field's own extent rather than by the lattice distance,
	-- so the falloff contours are circles - a hex-norm falloff would give the
	-- continent six visibly straight coasts.
	local score, key, wx, wy, allowed = {}, {}, {}, {}, {}
	local dmax = 0
	for i = 1, n do
		local q, r = cells[i][1], cells[i][2]
		local x, y = hex.to_world(q, r, 1)
		wx[i], wy[i] = x, y
		key[i] = hex.key(q, r)
		allowed[i] = hex.distance(q, r, 0, 0) <= inner
		local d = sqrt(x * x + y * y)
		if d > dmax then dmax = d end
	end
	if dmax <= 0 then dmax = 1 end

	for i = 1, n do
		local nd = sqrt(wx[i] * wx[i] + wy[i] * wy[i]) / dmax
		local toward = 1 - nd * nd * pull
		local f = noise.fbm(nseed, wx[i] * freq, wy[i] * freq, octaves)
		score[i] = toward + amp * (f - 0.5)
	end

	-- Index by key so the frontier can find a cell's score without searching.
	local index = {}
	for i = 1, n do index[key[i]] = i end

	-- Start at the best-scoring cell. Ties go to the lower field index, which is
	-- a fixed scan order, so this never depends on table iteration.
	local start, best = nil, -math.huge
	for i = 1, n do
		if allowed[i] and score[i] > best then
			start, best = i, score[i]
		end
	end
	if not start then return {}, {}, cells end

	local claimed = {}
	local land = {}
	local frontier = {}   -- candidate field indices, may contain stale entries

	local function claim(i)
		claimed[key[i]] = true
		land[#land + 1] = cells[i]
		local q, r = cells[i][1], cells[i][2]
		for d = 1, #hex.DIRECTIONS do
			local dir = hex.DIRECTIONS[d]
			local j = index[hex.key(q + dir[1], r + dir[2])]
			if j and allowed[j] and not claimed[key[j]] then
				frontier[#frontier + 1] = j
			end
		end
	end

	claim(start)

	while #land < target do
		-- Best remaining cell on the frontier. Compacting stale entries in place
		-- rather than swap-popping inside the scan: Lua evaluates a numeric
		-- for's limit once, so shrinking the array under it runs the index off
		-- the end. Same shape as the region growth in galaxy/graph.lua.
		local w = 0
		for i = 1, #frontier do
			local e = frontier[i]
			if not claimed[key[e]] then
				w = w + 1
				frontier[w] = e
			end
		end
		for i = #frontier, w + 1, -1 do frontier[i] = nil end
		if w == 0 then break end

		local pick, pickscore = nil, -math.huge
		for i = 1, w do
			local e = frontier[i]
			if score[e] > pickscore then
				pick, pickscore = e, score[e]
			end
		end
		if not pick then break end
		claim(pick)
	end

	local is_land = {}
	for i = 1, #land do
		is_land[hex.key(land[i][1], land[i][2])] = true
	end

	return land, is_land, M.shore(is_land, cells, SEA_MARGIN)
end

--- The sea worth drawing: field cells within `margin` steps of land.
--
-- Grown outward ring by ring from the coast rather than filtered by distance,
-- so it costs the length of the coastline rather than the area of the field -
-- and so the ocean's outer edge follows the continent instead of being the
-- hexagon the field happens to be.
--
-- Emitted in the field's own scan order, which is fixed, so the client and the
-- server produce the same array rather than merely the same set. `galaxy/wire.lua`
-- rebuilds the sea by calling this, because it is exactly the subtraction the
-- client can do for itself.
function M.shore(is_land, cells, margin)
	local infield = {}
	for i = 1, #cells do infield[hex.key(cells[i][1], cells[i][2])] = true end

	local seen = {}
	local frontier = {}
	for i = 1, #cells do
		local k = hex.key(cells[i][1], cells[i][2])
		if is_land[k] then
			seen[k] = true
			frontier[#frontier + 1] = cells[i]
		end
	end

	local water_set = {}
	for _ = 1, margin do
		local next_frontier = {}
		for i = 1, #frontier do
			local q, r = frontier[i][1], frontier[i][2]
			for d = 1, #hex.DIRECTIONS do
				local dir = hex.DIRECTIONS[d]
				local nq, nr = q + dir[1], r + dir[2]
				local k = hex.key(nq, nr)
				if infield[k] and not seen[k] then
					seen[k] = true
					water_set[k] = true
					next_frontier[#next_frontier + 1] = { nq, nr }
				end
			end
		end
		frontier = next_frontier
	end

	-- Back into field scan order: the ring walk visits cells in whatever order
	-- the frontier happened to hold them, and that must not reach the wire.
	local water = {}
	for i = 1, #cells do
		if water_set[hex.key(cells[i][1], cells[i][2])] then
			water[#water + 1] = cells[i]
		end
	end
	return water
end

--- The radius the continent is grown inside, for `target` cells at `fill`.
--
-- The full field is this plus `M.SEA_MARGIN`, which `M.build` adds itself.
function M.radius_for(target, fill)
	fill = fill or 0.55
	local want = target / fill
	local radius = 1
	while hex.field_size(radius) < want do radius = radius + 1 end
	return radius
end

return M
