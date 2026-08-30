-- The hex lattice and the continent grown on it.
-- Run: luajit tools/test_hex.lua
--
-- These exist because the whole map now rests on two claims that are cheap to
-- state and expensive to discover wrong: that the art's 238x207 tile is exactly
-- a flat-top hexagon's bounding box (get it wrong and the map tiles with gaps
-- nobody can explain), and that the land is one connected piece (get it wrong
-- and a player is islanded with no move, several turns into a real game).
package.path = "./?.lua;" .. package.path
local hex = require("realm.hex")
local land_mod = require("realm.land")
local terrain = require("realm.terrain")
local gen = require("realm.generate")
local config = require("realm.config")
local influence = require("realm.influence")

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
	return math.abs(a - b) <= (eps or 1e-9)
end

print("the lattice")
do
	local bad = nil
	for r = 0, 14 do
		if #hex.field(r) ~= hex.field_size(r) then bad = r end
	end
	check("a field holds 1 + 3N(N+1) cells", bad == nil, "radius " .. tostring(bad))

	-- Every direction is one step, and every direction has an opposite that
	-- comes back. The order of DIRECTIONS is load-bearing (adjacency arrays are
	-- built by walking it, so reordering moves every seed's digest) but its
	-- *symmetry* is what makes the graph undirected.
	local one_step, reciprocal = true, true
	for i = 1, #hex.DIRECTIONS do
		local d = hex.DIRECTIONS[i]
		if hex.distance(0, 0, d[1], d[2]) ~= 1 then one_step = false end
		local back = false
		for j = 1, #hex.DIRECTIONS do
			local e = hex.DIRECTIONS[j]
			if e[1] == -d[1] and e[2] == -d[2] then back = true end
		end
		if not back then reciprocal = false end
	end
	check("all six neighbours are exactly one step away", one_step)
	check("and every direction has its opposite", reciprocal)
	check("there are six of them", #hex.DIRECTIONS == 6)

	-- The real geometric claim: on a flat-top grid every neighbour's centre is
	-- the same distance away, which is what makes one hex one step honest.
	local size = 70
	local d0 = nil
	local uniform = true
	for i = 1, #hex.DIRECTIONS do
		local d = hex.DIRECTIONS[i]
		local x, y = hex.to_world(d[1], d[2], size)
		local dist = math.sqrt(x * x + y * y)
		d0 = d0 or dist
		if not approx(dist, d0, 1e-9) then uniform = false end
	end
	check("every neighbour centre is the same distance away", uniform,
		"got " .. tostring(d0))
	check("and that distance is sqrt(3) * size",
		approx(d0, hex.SQRT3 * size, 1e-9), tostring(d0))

	-- Keys have to be unique across the whole field or the sparse tables the
	-- generator builds with would silently merge two cells into one.
	local seen, collision = {}, nil
	for _, c in ipairs(hex.field(14)) do
		local k = hex.key(c[1], c[2])
		if seen[k] then collision = k end
		seen[k] = true
	end
	check("cell keys are unique across a field", collision == nil, tostring(collision))
end

print("political influence")
do
	local function mask(owner, ...)
		return influence.mask(owner, { ... })
	end
	check("an isolated holding exposes all six sides",
		mask(1, 0, 0, 0, 0, 0, 0) == 63)
	check("an adjacent friendly tile removes only their shared side",
		mask(1, 1, 0, 0, 0, 0, 0) == 62
			and mask(1, 0, 0, 0, 1, 0, 0) == 55)
	check("fully enclosed territory has no outline sprite",
		mask(1, 1, 1, 1, 1, 1, 1) == 0)
	check("unowned coast closes the outline",
		mask(1, 1, 1, 1, 0, 1, 1) == 8)
	check("a rival exposes the shared side",
		mask(1, 1, 2, 1, 1, 1, 1) == 2)
	check("unowned tiles never draw influence",
		mask(0, 1, 1, 1, 1, 1, 1) == 0)
	check("disconnected holdings are outlined independently",
		mask(3, 0, 0, 0, 0, 0, 0) == 63
			and mask(3, 0, 0, 0, 3, 0, 0) == 55)

	local source = io.open("main/influence.atlas", "r")
	local atlas = source and source:read("*a") or ""
	if source then source:close() end
	local all_images, deterministic = source ~= nil, true
	for value = 1, influence.FULL_MASK do
		local first = influence.image(value)
		local second = influence.image(value)
		if first ~= second then deterministic = false end
		if not atlas:find("/" .. first .. ".png", 1, true) then all_images = false end
		local png = io.open("main/assets/influence/" .. first .. ".png", "rb")
		if not png then all_images = false else png:close() end
	end
	check("mask naming is deterministic", deterministic)
	check("every nonzero mask resolves to an atlas image", all_images,
		"run python3 tools/make_influence_atlas.py")
	check("zero has no atlas image", influence.image(0) == nil)
end

print("the art fits the lattice")
do
	-- 238x207 is the tile the foundation_tiles pack ships, and the sprite is
	-- drawn at its native size. If this stops holding the map tiles with visible
	-- gaps or overlaps, and the cause is nowhere near the renderer.
	local size = 238 / 2
	local corners = hex.corners(0, 0, size)
	local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
	for i = 1, #corners, 2 do
		if corners[i] < minx then minx = corners[i] end
		if corners[i] > maxx then maxx = corners[i] end
		if corners[i + 1] < miny then miny = corners[i + 1] end
		if corners[i + 1] > maxy then maxy = corners[i + 1] end
	end
	check("a hexagon of size 119 is 238 wide", approx(maxx - minx, 238, 1e-9),
		tostring(maxx - minx))
	-- The true height is sqrt(3) * 119 = 206.114, and the art is 207: the
	-- artist rounded up to a whole pixel. That is the right direction to be
	-- wrong in - a sprite drawn at native size overlaps its neighbour by under
	-- a pixel rather than leaving a gap, and Defold premultiplies alpha so the
	-- transparent overlap is an exact no-op. A tolerance under 1 here fails on
	-- correct art; a tolerance over 2 would stop catching a genuinely wrong
	-- aspect ratio.
	local ideal = maxy - miny
	check("and 207 tall, the art's own rounding up of 206.114",
		ideal < 207 and (207 - ideal) < 1.0,
		string.format("ideal %.3f vs art 207", ideal))
	check("it has six corners", #corners == 12)
end

print("the continent")
do
	local radius = land_mod.radius_for(config.land_target, config.field_fill)
	check("the field is comfortably bigger than the land",
		hex.field_size(radius) > config.land_target * 1.5,
		hex.field_size(radius) .. " cells for " .. config.land_target .. " land")

	local seeds = { 1, 42, 1337, 424242, 999983, 16777215, 7, 2024 }
	local bad_count, bad_conn, bad_repeat = nil, nil, nil
	for _, seed in ipairs(seeds) do
		local cells, is_land = land_mod.build(seed, radius, config.land_target)
		if #cells ~= config.land_target then bad_count = seed end

		-- Connectivity checked by flooding, deliberately *not* by trusting the
		-- growth that produced it: the claim is the point of the module, so the
		-- test must be able to fail independently of it.
		local seen = { [hex.key(cells[1][1], cells[1][2])] = true }
		local stack, reached = { cells[1] }, 1
		while #stack > 0 do
			local c = table.remove(stack)
			for i = 1, #hex.DIRECTIONS do
				local d = hex.DIRECTIONS[i]
				local q, r = c[1] + d[1], c[2] + d[2]
				local k = hex.key(q, r)
				if is_land[k] and not seen[k] then
					seen[k] = true
					reached = reached + 1
					stack[#stack + 1] = { q, r }
				end
			end
		end
		if reached ~= #cells then bad_conn = seed .. ": " .. reached .. "/" .. #cells end

		local again = land_mod.build(seed, radius, config.land_target)
		for i = 1, #cells do
			if again[i][1] ~= cells[i][1] or again[i][2] ~= cells[i][2] then
				bad_repeat = bad_repeat or seed
			end
		end
	end
	check("every seed lands on the exact land target", bad_count == nil,
		"seed " .. tostring(bad_count))
	check("the land is one connected piece", bad_conn == nil, tostring(bad_conn))
	check("and the same seed grows it identically", bad_repeat == nil,
		"seed " .. tostring(bad_repeat))
end

print("the generated map")
do
	local g = gen.build(424242)

	check("land count matches the config", #g.tiles == config.land_target,
		tostring(#g.tiles))
	-- The drawn sea is a band following the coast, not the whole field: it costs
	-- the length of the coastline rather than the area of the map, and its outer
	-- edge is the continent's shape rather than the hexagon the field happens to
	-- be. Both halves of that have to hold - no water further out than the
	-- margin, and no gap inside it.
	local land_keys, water_keys = {}, {}
	for i = 1, #g.tiles do land_keys[hex.key(g.tiles[i].q, g.tiles[i].r)] = true end
	for i = 1, #g.water do water_keys[hex.key(g.water[i].q, g.water[i].r)] = true end

	local function steps_to_land(q, r)
		local best = math.huge
		for i = 1, #g.tiles do
			local d = hex.distance(q, r, g.tiles[i].q, g.tiles[i].r)
			if d < best then best = d end
		end
		return best
	end

	local too_far, missing_water = nil, nil
	for i = 1, #g.water do
		local w = g.water[i]
		if steps_to_land(w.q, w.r) > land_mod.SEA_MARGIN then
			too_far = w.q .. "," .. w.r
		end
	end
	local field = hex.field(g.field_radius)
	for i = 1, #field do
		local q, r = field[i][1], field[i][2]
		local k = hex.key(q, r)
		if not land_keys[k] and not water_keys[k]
			and steps_to_land(q, r) <= land_mod.SEA_MARGIN then
			missing_water = q .. "," .. r
		end
	end
	check("no drawn sea is further from land than the margin", too_far == nil,
		tostring(too_far))
	check("and every cell inside the margin is drawn", missing_water == nil,
		tostring(missing_water))
	check("the continent never reaches the edge of the field", (function()
		for i = 1, #g.tiles do
			if hex.distance(g.tiles[i].q, g.tiles[i].r, 0, 0) >= g.field_radius then
				return false, "tile " .. i
			end
		end
		return true
	end)())
	check("the graph reports itself connected", g.stats.connected)

	-- Adjacency must agree with the lattice exactly: no self-loops, symmetric,
	-- and every entry a genuine neighbour. The resolver walks these lists for
	-- every move of every turn.
	local index = {}
	for i = 1, #g.tiles do index[hex.key(g.tiles[i].q, g.tiles[i].r)] = i end
	local self_loop, asymmetric, not_neighbour, missing = nil, nil, nil, nil
	for i = 1, #g.tiles do
		local s = g.tiles[i]
		local have = {}
		for _, j in ipairs(g.adjacency[i]) do
			have[j] = true
			if j == i then self_loop = i end
			local back = false
			for _, k in ipairs(g.adjacency[j]) do
				if k == i then back = true end
			end
			if not back then asymmetric = i .. "->" .. j end
			if hex.distance(s.q, s.r, g.tiles[j].q, g.tiles[j].r) ~= 1 then
				not_neighbour = i .. "->" .. j
			end
		end
		-- and nothing adjacent on the lattice is left out
		for d = 1, #hex.DIRECTIONS do
			local dir = hex.DIRECTIONS[d]
			local j = index[hex.key(s.q + dir[1], s.r + dir[2])]
			if j and not have[j] then missing = i .. "->" .. j end
		end
	end
	check("no tile is its own neighbour", self_loop == nil, tostring(self_loop))
	check("adjacency is symmetric", asymmetric == nil, tostring(asymmetric))
	check("every entry is a lattice neighbour", not_neighbour == nil,
		tostring(not_neighbour))
	check("and no lattice neighbour is left out", missing == nil, tostring(missing))

	-- No sea tile may appear in the graph. This is the invariant the whole
	-- "water needs no impassability logic" argument rests on.
	local water_keys = {}
	for _, w in ipairs(g.water) do water_keys[hex.key(w.q, w.r)] = true end
	local sea_in_graph = nil
	for i = 1, #g.tiles do
		if water_keys[hex.key(g.tiles[i].q, g.tiles[i].r)] then sea_in_graph = i end
	end
	check("no sea tile is in the graph at all", sea_in_graph == nil,
		tostring(sea_in_graph))

	-- Everything the renderer and the sim will look up has to resolve.
	local biomes = {}
	for _, b in ipairs(terrain.BIOMES) do biomes[b] = true end
	local bad_terrain, bad_biome, bad_feature, water_on_land = nil, nil, nil, nil
	for i = 1, #g.tiles do
		local s = g.tiles[i]
		if not terrain.by_id(s.terrain) then bad_terrain = s.terrain end
		if s.terrain == "water" then water_on_land = i end
		if not biomes[s.biome] then bad_biome = s.biome end
		if not terrain.feature_by_id(s.feature) then bad_feature = s.feature end
	end
	check("every tile has a terrain in the table", bad_terrain == nil, tostring(bad_terrain))
	check("no land tile is sea", water_on_land == nil, tostring(water_on_land))
	check("every tile has a declared biome", bad_biome == nil, tostring(bad_biome))
	check("every tile has a feature in the table", bad_feature == nil, tostring(bad_feature))

	-- Province carving still has to produce something playable on the new
	-- substrate: every tile in a province, every province non-empty.
	local unassigned, empty = nil, nil
	local counted = {}
	for i = 1, #g.provinces do counted[i] = 0 end
	for i = 1, #g.tiles do
		local r = g.tiles[i].province
		if not r or not counted[r] then unassigned = i else counted[r] = counted[r] + 1 end
	end
	for i = 1, #g.provinces do
		if counted[i] == 0 then empty = i end
	end
	check("every tile belongs to a province", unassigned == nil, tostring(unassigned))
	check("and no province is empty", empty == nil, tostring(empty))
end

if failures == 0 then
	print("\nALL HEX TESTS PASSED")
	os.exit(0)
end
print(string.format("\n%d FAILURE(S)", failures))
os.exit(1)
