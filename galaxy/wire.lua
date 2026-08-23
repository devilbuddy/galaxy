--- Wire format for sending a generated galaxy from the server to the client.
--
-- Engine-free, and shared verbatim by Nakama and Defold, so there is exactly
-- one definition of the contract rather than an encoder and a decoder that can
-- drift apart.
--
-- Only what cannot be derived is transmitted. Star colours, radii, labels,
-- region palette entries, lane border flags, the adjacency lists and the
-- content bounds are all recomputed on arrival from the same tables the
-- generator used, which keeps the payload to the irreducible facts: where the
-- stars are, what they are called, and what connects to what.

local starclass = require("galaxy.starclass")
local config = require("galaxy.config")

local M = {}

-- Bump when the shape below changes incompatibly; the client refuses a payload
-- it does not understand rather than rendering a half-decoded map.
M.VERSION = 1

--- Pack a generated galaxy into plain tables ready for JSON encoding.
function M.encode(g)
	local stars = {}
	for i = 1, #g.stars do
		local s = g.stars[i]
		stars[i] = {
			x = s.x, y = s.y,
			name = s.name,
			class = s.class,
			feature = s.feature,
			region = s.region,
			jitter = s.size_jitter,
			hab = s.habitable and 1 or 0,
		}
	end

	local lanes = {}
	for i = 1, #g.lanes do
		lanes[i] = { a = g.lanes[i].a, b = g.lanes[i].b }
	end

	local regions = {}
	for i = 1, #g.regions do
		local r = g.regions[i]
		regions[i] = { name = r.name, colour = r.colour_index, capital = r.capital }
	end

	return {
		v = M.VERSION,
		seed = g.seed,
		world = g.world_size,
		stars = stars,
		lanes = lanes,
		regions = regions,
	}
end

--- Rebuild the full structure the renderer and HUD expect.
--
-- Mirrors the tail of galaxy/generate.lua: everything derived there from the
-- class and palette tables is derived here too, so a galaxy that arrived over
-- the network is indistinguishable from one generated locally.
function M.decode(t)
	assert(type(t) == "table", "galaxy payload is not a table")
	assert(t.v == M.VERSION,
		string.format("unsupported galaxy wire version %s (expected %d)",
			tostring(t.v), M.VERSION))

	local palette = config.region_palette
	local world = t.world
	local n = #t.stars

	local regions = {}
	for i = 1, #t.regions do
		local r = t.regions[i]
		local index = r.colour
		regions[i] = {
			id = i,
			name = r.name,
			colour_index = index,
			colour = palette[index] or palette[1],
			capital = r.capital,
			star_count = 0,
			cx = 0, cy = 0,
			neighbours = {},
		}
	end

	local minx, miny = math.huge, math.huge
	local maxx, maxy = -math.huge, -math.huge

	local stars = {}
	for i = 1, n do
		local s = t.stars[i]
		local class = starclass.by_id(s.class) or starclass.CLASSES[1]
		local feature = starclass.feature_by_id(s.feature) or starclass.FEATURES[1]
		stars[i] = {
			id = i,
			nx = s.x / (world * 0.5), ny = s.y / (world * 0.5),
			x = s.x, y = s.y,
			name = s.name,
			class = class.id,
			class_label = class.label,
			colour = class.colour,
			radius = class.radius,
			glow = class.glow,
			feature = feature.id,
			feature_label = feature.label,
			region = s.region,
			size_jitter = s.jitter,
			-- JSON has no integer/boolean distinction worth relying on across
			-- two runtimes, so this is sent as 0/1 and normalised here.
			habitable = (s.hab == 1 or s.hab == true),
		}
		if s.x < minx then minx = s.x end
		if s.y < miny then miny = s.y end
		if s.x > maxx then maxx = s.x end
		if s.y > maxy then maxy = s.y end

		local rg = regions[s.region]
		if rg then
			rg.star_count = rg.star_count + 1
			rg.cx = rg.cx + s.x
			rg.cy = rg.cy + s.y
		end
	end

	for i = 1, #regions do
		local rg = regions[i]
		if rg.star_count > 0 then
			rg.cx = rg.cx / rg.star_count
			rg.cy = rg.cy / rg.star_count
		end
	end

	local adjacency = {}
	for i = 1, n do adjacency[i] = {} end

	local neighbour_set = {}
	for i = 1, #regions do neighbour_set[i] = {} end

	local lanes = {}
	for i = 1, #t.lanes do
		local a, b = t.lanes[i].a, t.lanes[i].b
		local sa, sb = stars[a], stars[b]
		local dx, dy = sa.x - sb.x, sa.y - sb.y
		local border = sa.region ~= sb.region
		lanes[i] = {
			a = a, b = b,
			length = math.sqrt(dx * dx + dy * dy),
			border = border,
		}
		adjacency[a][#adjacency[a] + 1] = b
		adjacency[b][#adjacency[b] + 1] = a
		if border then
			neighbour_set[sa.region][sb.region] = true
			neighbour_set[sb.region][sa.region] = true
		end
	end
	for i = 1, n do table.sort(adjacency[i]) end
	for i = 1, #regions do
		local list = {}
		for j in pairs(neighbour_set[i]) do list[#list + 1] = j end
		table.sort(list) -- pairs() order is undefined; sorting keeps this stable
		regions[i].neighbours = list
	end

	if n == 0 then
		minx, miny, maxx, maxy = -world * 0.5, -world * 0.5, world * 0.5, world * 0.5
	end

	return {
		seed = t.seed,
		stars = stars,
		lanes = lanes,
		regions = regions,
		adjacency = adjacency,
		world_size = world,
		bounds = { -world * 0.5, -world * 0.5, world * 0.5, world * 0.5 },
		content = {
			min_x = minx, min_y = miny, max_x = maxx, max_y = maxy,
			centre_x = (minx + maxx) * 0.5,
			centre_y = (miny + maxy) * 0.5,
			width = maxx - minx,
			height = maxy - miny,
		},
		stats = {
			star_count = n,
			lane_count = #lanes,
			region_count = #regions,
			mean_degree = n > 0 and (2 * #lanes / n) or 0,
			connected = true, -- the server only ever emits a connected graph
			reached = n,
		},
	}
end

return M
