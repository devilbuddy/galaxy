--- Top-level generator: a seed in, a complete map out.
--
-- The whole pipeline is pure Lua with no engine dependency, so it can be run
-- and inspected offline (see tools/) as well as inside Defold. Nothing here
-- reads the clock, `math.random`, or iterates a hash table in a way that
-- affects output, which is what makes a seed reproduce exactly.
--
-- The map is a **hex lattice**: one continent grown cell by cell out of a sea,
-- with adjacency the six neighbours rather than a network of drawn connections.
-- Two consequences run through everything below:
--
--   * **Sea tiles are not in the graph at all.** Land is indexed 1..N and
--     `adjacency` covers land only, so the simulation keeps its invariant that
--     every id is a place a commander can stand and needs no impassability
--     logic anywhere. Water blocks movement because it is unreachable, not
--     because something checks.
--   * **There is no transcendental arithmetic.** Value noise is an integer hash,
--     a lerp and a quintic polynomial; the only library call is `sqrt`, which
--     IEEE requires to be correctly rounded. The spiral density field this
--     replaces had to be quantised to a coarse ladder because `exp`, `log` and
--     `atan2` can differ in the last bit between macOS libm, glibc and bionic.
--     Nothing here can, so nothing here is quantised. **Do not reintroduce one
--     without reintroducing the ladder with it.**

local rng = require("galaxy.rng")
local hex = require("galaxy.hex")
local land_mod = require("galaxy.land")
local noise = require("galaxy.noise")
local graph = require("galaxy.graph")
local names_mod = require("galaxy.names")
local terrain_mod = require("galaxy.terrain")
local defaults = require("galaxy.config")

local M = {}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

-- The noise fields the terrain is read off, in units of the hex size. Higher
-- than the coast's own frequency (galaxy/land.lua) on purpose: the coastline
-- wants lobes several hexes across, while terrain wants to change within a
-- province without becoming confetti.
--
-- `blight` is coarse and sparse - deadlands are a scar on the map, not a
-- climate - and `warm` only wobbles the latitude band so the ice line is not a
-- ruled horizontal.
local FIELD = {
	elevation = { freq = 0.30, octaves = 4 },
	moisture  = { freq = 0.26, octaves = 4 },
	blight    = { freq = 0.12, octaves = 3 },
	warm      = { freq = 0.14, octaves = 2 },
}

-- How far the wobble is allowed to move the ice line, as a fraction of the map's
-- half-height. Enough for a ragged treeline, not enough to put ice at the
-- equator.
local WARM_WOBBLE = 0.30

--- Each value's position in the sorted order of the whole array, in [0, 1).
--
-- Turns a noise sample into the fraction of the map that scores below it, which
-- is what lets galaxy/terrain.lua's thresholds be read as the proportions they
-- are. Ties break by index so the result never depends on sort stability, which
-- Lua does not promise.
local function ranks(values)
	local n = #values
	local order = {}
	for i = 1, n do order[i] = i end
	table.sort(order, function(p, q)
		if values[p] ~= values[q] then return values[p] < values[q] end
		return p < q
	end)
	local out = {}
	for k = 1, n do out[order[k]] = (k - 1) / n end
	return out
end

--- Shallow merge of caller overrides onto the defaults.
local function merged(cfg)
	local out = {}
	for k, v in pairs(defaults) do out[k] = v end
	if cfg then
		for k, v in pairs(cfg) do out[k] = v end
	end
	return out
end

--- Generate a map.
-- @param seed integer
-- @param cfg  optional overrides of galaxy/config.lua
function M.build(seed, cfg)
	cfg = merged(cfg)
	seed = floor(seed or 0)

	local size = cfg.hex_size
	-- The growable disc. The field itself is this plus land_mod.SEA_MARGIN,
	-- which is where the drawn ocean lives.
	local inner = land_mod.radius_for(cfg.land_target, cfg.field_fill)
	local radius = inner + land_mod.SEA_MARGIN

	-- 1. The continent. Connected by construction - see galaxy/land.lua.
	local cells, is_land, water_cells = land_mod.build(seed, inner, cfg.land_target)
	local n = #cells

	-- 2. Index the land, and derive adjacency from the six neighbours.
	--
	-- The edge list is built only so the region carver has one: `graph.regions`
	-- and `graph.region_adjacency` are written against index pairs and work
	-- unchanged on a lattice. It is deliberately *not* returned - on a hex map
	-- adjacency is the six neighbours and a list of drawn connections would be a
	-- second description of the same fact, free to drift.
	local index = {}
	for i = 1, n do index[hex.key(cells[i][1], cells[i][2])] = i end

	local edges = {}
	for i = 1, n do
		local q, r = cells[i][1], cells[i][2]
		for d = 1, #hex.DIRECTIONS do
			local dir = hex.DIRECTIONS[d]
			local j = index[hex.key(q + dir[1], r + dir[2])]
			-- Each edge once, with the lower index first: graph.regions keys its
			-- cost table that way and reads it back normalised.
			if j and i < j then edges[#edges + 1] = { i, j } end
		end
	end
	local adj = graph.adjacency(n, edges)

	-- World positions. `pts` is what the region carver measures distance with,
	-- so it is the same coordinates, just in the shape that module expects.
	local pts = {}
	local xs, ys = {}, {}
	for i = 1, n do
		local x, y = hex.to_world(cells[i][1], cells[i][2], size)
		xs[i], ys[i] = x, y
		pts[i] = { x = x, y = y }
	end

	-- 3. Carve into regions. Unchanged from the star map: balanced growth along
	--    adjacency, which keeps every region contiguous and comparable in size.
	local region_count = floor(n / cfg.stars_per_region + 0.5)
	region_count = max(cfg.min_regions, min(cfg.max_regions, region_count))
	local owner, seeds = graph.regions(rng.stream(seed, "regions"), pts, edges, adj, region_count)
	local radj = graph.region_adjacency(owner, edges, region_count)
	local palette = cfg.region_palette
	local colour_index = graph.colour_regions(radj, #palette, region_count)

	-- 4. Name everything. Regions first so the strongest vocabulary lands on the
	--    labels the player sees at every zoom level.
	local namer = names_mod.new(rng.stream(seed, "names"))
	local regions = {}
	for i = 1, region_count do
		regions[i] = {
			id = i,
			name = namer:region(),
			colour_index = colour_index[i],
			colour = palette[colour_index[i]],
			capital = seeds[i],
			star_count = 0,
			cx = 0, cy = 0,
			neighbours = radj[i],
		}
	end

	-- 5. Terrain, biome and feature, off the noise fields.
	--
	-- Two passes, because galaxy/terrain.lua thresholds on **ranks** rather than
	-- on raw noise: the whole map has to be sampled before any of it can be
	-- classified. See the note on `M.classify` for why - absolute thresholds on
	-- fractal noise pick a tiny tail rather than the share they look like.
	local nseed = {}
	for k in pairs(FIELD) do nseed[k] = rng.stream(seed, "field:" .. k):u32() end

	local function sample(field, i)
		local f = FIELD[field]
		-- Sampled in units of the hex size, so retuning `hex_size` rescales the
		-- whole map without changing which tile is which.
		return noise.fbm(nseed[field], xs[i] / size * f.freq, ys[i] / size * f.freq,
			f.octaves)
	end

	local elevation, moisture, blight, wobble = {}, {}, {}, {}
	local maxlat = 0
	for i = 1, n do
		elevation[i] = sample("elevation", i)
		moisture[i] = sample("moisture", i)
		blight[i] = sample("blight", i)
		wobble[i] = sample("warm", i)
		local a = abs(ys[i])
		if a > maxlat then maxlat = a end
	end
	local elev_rank = ranks(elevation)
	local moist_rank = ranks(moisture)
	local blight_rank = ranks(blight)
	if maxlat <= 0 then maxlat = 1 end

	local feature_rng = rng.stream(seed, "features")
	local hab_rng = rng.stream(seed, "habitable")

	local stars = {}
	for i = 1, n do
		-- Latitude is measured against the **continent's** own extent, not the
		-- field's. The land never reaches the rim, so measuring against the field
		-- put the ice line off the top of the map and left four icelands tiles on
		-- a 220-tile continent. A cold map should be able to be cold.
		-- **A curved falloff, not a linear one.** Warmth is flat across the
		-- middle latitudes and drops away fast towards the ends, which is what
		-- gives an equatorial belt and two caps rather than a smooth gradient
		-- from top to bottom. Linear put the ice line at 70% of the way to the
		-- pole and iced nearly half the continent; squared puts it at 74% of the
		-- way with the threshold galaxy/terrain.lua uses, which is a cap.
		local lat = abs(ys[i]) / maxlat
		local warmth = 1 - lat * lat + WARM_WOBBLE * (wobble[i] - 0.5)
		if warmth < 0 then warmth = 0 elseif warmth > 1 then warmth = 1 end

		local ground = terrain_mod.classify(elev_rank[i], moist_rank[i])
		local entry = terrain_mod.by_id(ground)
		local feature = terrain_mod.roll_feature(feature_rng)
		local region = owner[i]

		stars[i] = {
			id = i,
			-- Lattice coordinates alongside world pixels: generation and the
			-- wire reason in whole cells, rendering wants units.
			q = cells[i][1], r = cells[i][2],
			x = xs[i], y = ys[i],
			name = namer:system(),
			terrain = ground,
			terrain_label = entry.label,
			biome = terrain_mod.biome(warmth, moist_rank[i], blight_rank[i]),
			feature = feature.id,
			feature_label = feature.label,
			region = region,
			habitable = hab_rng:float() < entry.habitable,
		}

		local rg = regions[region]
		rg.star_count = rg.star_count + 1
		rg.cx = rg.cx + xs[i]
		rg.cy = rg.cy + ys[i]
	end

	for i = 1, region_count do
		local rg = regions[i]
		if rg.star_count > 0 then
			rg.cx = rg.cx / rg.star_count
			rg.cy = rg.cy / rg.star_count
		end
	end

	-- 5b. Guarantee enough habitable land to be worth fighting over.
	--
	-- Unchanged in shape from the star map: the count is topped up
	-- deterministically, the terrain most likely to be habitable first with ties
	-- broken by index, which keeps the same seed reproducible while leaving
	-- *which* tiles are settled driven by the roll.
	local target = floor(n * (cfg.colony_fraction or 0) + 0.5)
	local habitable_count = 0
	for i = 1, n do
		if stars[i].habitable then habitable_count = habitable_count + 1 end
	end
	if habitable_count < target then
		local candidates = {}
		for i = 1, n do
			if not stars[i].habitable then
				local entry = terrain_mod.by_id(stars[i].terrain)
				candidates[#candidates + 1] = {
					id = i,
					-- Never zero, so a map of nothing but mountains can still
					-- be settled.
					weight = (entry and entry.habitable or 0) + 0.001,
				}
			end
		end
		table.sort(candidates, function(p, q)
			if p.weight ~= q.weight then return p.weight > q.weight end
			return p.id < q.id
		end)
		local promote = target - habitable_count
		for i = 1, #candidates do
			if promote <= 0 then break end
			stars[candidates[i].id].habitable = true
			promote = promote - 1
		end
	end

	-- 6. The sea, for the renderer alone. Positions only: nothing about a water
	--    tile is ever asked, because nothing can go there.
	local water = {}
	for i = 1, #water_cells do
		local q, r = water_cells[i][1], water_cells[i][2]
		local x, y = hex.to_world(q, r, size)
		water[i] = { q = q, r = r, x = x, y = y }
	end

	-- The populated extent, which is smaller than the field: the continent never
	-- reaches the rim. The camera frames this rather than the world, otherwise
	-- the map sits as a small island in the middle of the viewport.
	local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, n do
		local s = stars[i]
		if s.x < minx then minx = s.x end
		if s.y < miny then miny = s.y end
		if s.x > maxx then maxx = s.x end
		if s.y > maxy then maxy = s.y end
	end

	-- A square world box that the whole field fits inside, so the backdrop and
	-- the camera clamp have something stable to work against whatever shape the
	-- continent came out.
	local ex, ey2 = hex.extent(radius, size)
	local world = 2 * max(ex, ey2)
	local half = world * 0.5
	if n == 0 then minx, miny, maxx, maxy = -half, -half, half, half end

	for i = 1, n do
		stars[i].nx = stars[i].x / half
		stars[i].ny = stars[i].y / half
	end

	local connected, reached = graph.is_connected(n, adj)

	return {
		seed = seed,
		config = cfg,
		hex_size = size,
		field_radius = radius,
		stars = stars,
		water = water,
		regions = regions,
		adjacency = adj,
		world_size = world,
		bounds = { -half, -half, half, half },
		content = {
			min_x = minx, min_y = miny, max_x = maxx, max_y = maxy,
			centre_x = (minx + maxx) * 0.5,
			centre_y = (miny + maxy) * 0.5,
			width = maxx - minx,
			height = maxy - miny,
		},
		stats = {
			star_count = n,
			water_count = #water,
			edge_count = #edges,
			region_count = region_count,
			mean_degree = n > 0 and (2 * #edges / n) or 0,
			connected = connected,
			reached = reached,
		},
	}
end

return M
