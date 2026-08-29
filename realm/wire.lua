--- Wire format for sending a generated map from the server to the client.
--
-- Engine-free, and shared verbatim by Nakama and Defold, so there is exactly
-- one definition of the contract rather than an encoder and a decoder that can
-- drift apart.
--
-- Only what cannot be derived is transmitted. On a hex lattice that is a much
-- shorter list than it was for the tile map:
--
--   * **positions** are the lattice coordinates `(q, r)`, two small integers,
--     rather than two floats. World units are `hex.to_world`, so they are
--     recomputed rather than sent.
--   * **there are no connections to send at all.** Adjacency is the six
--     neighbours; the old format shipped an array of ~320 tiles because a
--     pruned Delaunay graph is genuinely arbitrary. A lattice is not.
--   * **the sea is not sent.** It is exactly the field minus the land, and the
--     field is `field_radius`, so the client subtracts one from the other.
--
-- Labels, province palette entries, centroids, adjacency, bounds and the content
-- extent are all recomputed on arrival from the same tables the generator used.

local hex = require("realm.hex")
local land = require("realm.land")
local terrain = require("realm.terrain")
local config = require("realm.config")

local M = {}

-- Bump when the shape below changes incompatibly; the client refuses a payload
-- it does not understand rather than rendering a half-decoded map. Version 2 is
-- the hex lattice - a version 1 payload describes a tile map that no longer has
-- anything to draw it.
M.VERSION = 2

--- Pack a generated map into plain tables ready for JSON encoding.
function M.encode(g)
	local tiles = {}
	for i = 1, #g.tiles do
		local s = g.tiles[i]
		tiles[i] = {
			q = s.q, r = s.r,
			name = s.name,
			terrain = s.terrain,
			biome = s.biome,
			feature = s.feature,
			province = s.province,
			hab = s.habitable and 1 or 0,
		}
	end

	local provinces = {}
	for i = 1, #g.provinces do
		local r = g.provinces[i]
		provinces[i] = { name = r.name, colour = r.colour_index, seat = r.seat }
	end

	return {
		v = M.VERSION,
		seed = g.seed,
		size = g.hex_size,
		radius = g.field_radius,
		tiles = tiles,
		provinces = provinces,
	}
end

--- Rebuild the full structure the renderer and HUD expect.
--
-- Mirrors the tail of realm/generate.lua: everything derived there from the
-- terrain and palette tables is derived here too, so a map that arrived over the
-- network is indistinguishable from one generated locally.
function M.decode(t)
	assert(type(t) == "table", "map payload is not a table")
	assert(t.v == M.VERSION,
		string.format("unsupported map wire version %s (expected %d)",
			tostring(t.v), M.VERSION))

	local palette = config.province_palette
	local size = t.size
	local radius = t.radius
	local n = #t.tiles

	local provinces = {}
	for i = 1, #t.provinces do
		local r = t.provinces[i]
		local index = r.colour
		provinces[i] = {
			id = i,
			name = r.name,
			colour_index = index,
			colour = palette[index] or palette[1],
			seat = r.seat,
			tile_count = 0,
			cx = 0, cy = 0,
			neighbours = {},
		}
	end

	local ex, ey = hex.extent(radius, size)
	local world = 2 * math.max(ex, ey)
	local half = world * 0.5

	local minx, miny = math.huge, math.huge
	local maxx, maxy = -math.huge, -math.huge

	local tiles = {}
	local index = {}
	for i = 1, n do
		local s = t.tiles[i]
		local ground = terrain.by_id(s.terrain) or terrain.TERRAIN[1]
		local feature = terrain.feature_by_id(s.feature) or terrain.FEATURES[1]
		local x, y = hex.to_world(s.q, s.r, size)
		tiles[i] = {
			id = i,
			q = s.q, r = s.r,
			x = x, y = y,
			nx = x / half, ny = y / half,
			name = s.name,
			terrain = ground.id,
			terrain_label = ground.label,
			biome = s.biome,
			feature = feature.id,
			feature_label = feature.label,
			province = s.province,
			-- JSON has no integer/boolean distinction worth relying on across
			-- two runtimes, so this is sent as 0/1 and normalised here.
			habitable = (s.hab == 1 or s.hab == true),
		}
		index[hex.key(s.q, s.r)] = i
		if x < minx then minx = x end
		if y < miny then miny = y end
		if x > maxx then maxx = x end
		if y > maxy then maxy = y end

		local rg = provinces[s.province]
		if rg then
			rg.tile_count = rg.tile_count + 1
			rg.cx = rg.cx + x
			rg.cy = rg.cy + y
		end
	end

	for i = 1, #provinces do
		local rg = provinces[i]
		if rg.tile_count > 0 then
			rg.cx = rg.cx / rg.tile_count
			rg.cy = rg.cy / rg.tile_count
		end
	end

	-- Adjacency and province borders, straight off the lattice. Same scan order as
	-- the generator's, so the neighbour lists come out identical rather than
	-- merely equivalent.
	local adjacency = {}
	for i = 1, n do adjacency[i] = {} end

	local neighbour_set = {}
	for i = 1, #provinces do neighbour_set[i] = {} end

	local edge_count = 0
	for i = 1, n do
		local s = tiles[i]
		for d = 1, #hex.DIRECTIONS do
			local dir = hex.DIRECTIONS[d]
			local j = index[hex.key(s.q + dir[1], s.r + dir[2])]
			if j then
				adjacency[i][#adjacency[i] + 1] = j
				if i < j then
					edge_count = edge_count + 1
					local ra, rb = s.province, tiles[j].province
					if ra ~= rb and neighbour_set[ra] and neighbour_set[rb] then
						neighbour_set[ra][rb] = true
						neighbour_set[rb][ra] = true
					end
				end
			end
		end
	end
	for i = 1, n do table.sort(adjacency[i]) end
	for i = 1, #provinces do
		local list = {}
		for j in pairs(neighbour_set[i]) do list[#list + 1] = j end
		table.sort(list) -- pairs() order is undefined; sorting keeps this stable
		provinces[i].neighbours = list
	end

	-- The sea: the band of field cells within reach of the coast. Not
	-- transmitted, because it is exactly this subtraction and the client already
	-- has both sides of it - and it goes through `land.shore`, the same function
	-- the generator used, so the two arrays match element for element rather
	-- than merely describing the same water.
	local is_land = {}
	for i = 1, n do is_land[hex.key(tiles[i].q, tiles[i].r)] = true end
	local shore = land.shore(is_land, hex.field(radius), land.SEA_MARGIN)
	local water = {}
	for i = 1, #shore do
		local q, r = shore[i][1], shore[i][2]
		local x, y = hex.to_world(q, r, size)
		water[i] = { q = q, r = r, x = x, y = y }
	end

	if n == 0 then
		minx, miny, maxx, maxy = -half, -half, half, half
	end

	return {
		seed = t.seed,
		hex_size = size,
		field_radius = radius,
		tiles = tiles,
		water = water,
		provinces = provinces,
		adjacency = adjacency,
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
			tile_count = n,
			water_count = #water,
			edge_count = edge_count,
			province_count = #provinces,
			mean_degree = n > 0 and (2 * edge_count / n) or 0,
			connected = true, -- the server only ever emits a connected continent
			reached = n,
		},
	}
end

return M
