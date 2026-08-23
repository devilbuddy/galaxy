--- Top-level generator: a seed in, a complete galaxy out.
--
-- The whole pipeline is pure Lua with no engine dependency, so it can be run
-- and inspected offline (see tools/) as well as inside Defold. Nothing here
-- reads the clock, `math.random`, or iterates a hash table in a way that
-- affects output, which is what makes a seed reproduce exactly.

local rng = require("galaxy.rng")
local shape_mod = require("galaxy.shape")
local points_mod = require("galaxy.points")
local delaunay = require("galaxy.delaunay")
local graph = require("galaxy.graph")
local names_mod = require("galaxy.names")
local starclass = require("galaxy.starclass")
local defaults = require("galaxy.config")

local M = {}

local sqrt, floor, min, max = math.sqrt, math.floor, math.min, math.max

--- Shallow merge of caller overrides onto the defaults.
local function merged(cfg)
	local out = {}
	for k, v in pairs(defaults) do out[k] = v end
	if cfg then
		for k, v in pairs(cfg) do out[k] = v end
	end
	return out
end

--- Generate a galaxy.
-- @param seed integer
-- @param cfg  optional overrides of galaxy/config.lua
function M.build(seed, cfg)
	cfg = merged(cfg)
	seed = floor(seed or 0)

	-- 1. The density field that decides where stars can exist.
	local shape = shape_mod.new(seed, cfg.shape)

	-- 2. Star positions, in the unit disc.
	local pts = points_mod.generate(seed, shape, cfg.star_count)
	local n = #pts

	-- 3. Triangulate, then thin to a lane network. Delaunay's planarity is what
	--    guarantees no two lanes ever cross on screen.
	local tris = delaunay.triangulate(pts)
	local all_edges = delaunay.edges(tris)
	local lanes = graph.prune(rng.stream(seed, "lanes"), pts, all_edges, {
		degree = cfg.lane_degree,
		jitter = cfg.lane_jitter,
	})
	local adj = graph.adjacency(n, lanes)

	-- 4. Carve into regions.
	local region_count = floor(n / cfg.stars_per_region + 0.5)
	region_count = max(cfg.min_regions, min(cfg.max_regions, region_count))
	local owner, seeds = graph.regions(rng.stream(seed, "regions"), pts, lanes, adj, region_count)
	local radj = graph.region_adjacency(owner, lanes, region_count)
	local palette = cfg.region_palette
	local colour_index = graph.colour_regions(radj, #palette, region_count)

	-- 5. Name everything. Regions are named first so the strongest vocabulary
	--    lands on the labels the player sees at every zoom level.
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

	-- 6. Classify and name each system.
	local class_rng = rng.stream(seed, "classes")
	local world = cfg.world_size
	local half = world * 0.5
	local stars = {}
	for i = 1, n do
		local p = pts[i]
		local r = sqrt(p.x * p.x + p.y * p.y)
		-- Bias exotic classes towards the galactic centre.
		local core_bias = 1.0 - (r > 1 and 1 or r)
		core_bias = core_bias * core_bias
		local class = starclass.roll_class(class_rng, core_bias)
		local feature = starclass.roll_feature(class_rng)
		local region = owner[i]

		stars[i] = {
			id = i,
			-- Unit-disc coordinates are kept alongside world pixels: generation
			-- reasons in normalised space, rendering wants pixels.
			nx = p.x, ny = p.y,
			x = p.x * half, y = p.y * half,
			name = namer:system(),
			class = class.id,
			class_label = class.label,
			colour = class.colour,
			radius = class.radius,
			glow = class.glow,
			feature = feature.id,
			feature_label = feature.label,
			region = region,
			-- Slight per-star size variation so a class does not look stamped.
			size_jitter = class_rng:range(0.88, 1.14),
			habitable = class_rng:float() < class.habitable,
		}

		local rg = regions[region]
		rg.star_count = rg.star_count + 1
		rg.cx = rg.cx + stars[i].x
		rg.cy = rg.cy + stars[i].y
	end

	for i = 1, region_count do
		local rg = regions[i]
		if rg.star_count > 0 then
			rg.cx = rg.cx / rg.star_count
			rg.cy = rg.cy / rg.star_count
		end
	end

	-- 7. Lanes in world units, tagged with whether they cross a border.
	local out_lanes = {}
	for i = 1, #lanes do
		local a, b = lanes[i][1], lanes[i][2]
		local sa, sb = stars[a], stars[b]
		local dx, dy = sa.x - sb.x, sa.y - sb.y
		out_lanes[i] = {
			a = a, b = b,
			length = sqrt(dx * dx + dy * dy),
			-- Border lanes are drawn differently: they are the chokepoints.
			border = sa.region ~= sb.region,
		}
	end

	-- The populated extent, which is much smaller than the nominal world box:
	-- the density falloff and the rim fraying mean stars never reach the
	-- corners. The camera frames this rather than the world, otherwise the
	-- galaxy sits as a small island in the middle of the viewport.
	local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, n do
		local s = stars[i]
		if s.x < minx then minx = s.x end
		if s.y < miny then miny = s.y end
		if s.x > maxx then maxx = s.x end
		if s.y > maxy then maxy = s.y end
	end
	if n == 0 then minx, miny, maxx, maxy = -half, -half, half, half end

	local connected, reached = graph.is_connected(n, adj)

	return {
		seed = seed,
		config = cfg,
		shape = shape,
		stars = stars,
		lanes = out_lanes,
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
			lane_count = #out_lanes,
			region_count = region_count,
			mean_degree = n > 0 and (2 * #out_lanes / n) or 0,
			connected = connected,
			reached = reached,
			arms = shape.arms,
		},
	}
end

return M
