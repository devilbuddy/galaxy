-- Round-trip test for the client/server wire format.
-- Run: luajit tools/test_wire.lua
package.path = "./?.lua;" .. package.path
local gen = require("realm.generate")
local wire = require("realm.wire")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. (detail or "")) end
end

for _, seed in ipairs({ 1, 424242, 1337 }) do
	local original = gen.build(seed)
	local rebuilt = wire.decode(wire.encode(original))
	print("seed " .. seed)

	check("tile count", #rebuilt.tiles == #original.tiles)
	check("sea rebuilt by subtraction", #rebuilt.water == #original.water,
		#rebuilt.water .. " vs " .. #original.water)
	check("province count", #rebuilt.provinces == #original.provinces)
	check("world size", rebuilt.world_size == original.world_size)

	local worst_pos, bad_field = 0, nil
	for i = 1, #original.tiles do
		local a, b = original.tiles[i], rebuilt.tiles[i]
		worst_pos = math.max(worst_pos, math.abs(a.x - b.x), math.abs(a.y - b.y))
		if a.name ~= b.name or a.terrain ~= b.terrain or a.feature ~= b.feature
			or a.biome ~= b.biome or a.province ~= b.province
			or a.habitable ~= b.habitable or a.q ~= b.q or a.r ~= b.r
			or a.terrain_label ~= b.terrain_label
			or a.feature_label ~= b.feature_label then
			bad_field = bad_field or ("tile " .. i .. " (" .. a.name .. ")")
		end
	end
	check("tile fields survive the round trip", bad_field == nil, tostring(bad_field))
	check("positions exact", worst_pos == 0, "worst delta " .. worst_pos)

	-- Nothing about connectivity is transmitted: adjacency is the six
	-- neighbours, so both sides derive it from the coordinates. Checking the
	-- *order* too, not just the count - the resolver walks these lists and a
	-- reordered one would find a different (equally short) route on each side.
	local bad_adj_order = nil
	for i = 1, #original.adjacency do
		local a, b = original.adjacency[i], rebuilt.adjacency[i]
		if #a ~= #b then
			bad_adj_order = bad_adj_order or ("size at " .. i)
		else
			for k = 1, #a do
				if a[k] ~= b[k] then bad_adj_order = bad_adj_order or ("order at " .. i) end
			end
		end
	end
	check("adjacency rederived from the lattice, in order",
		bad_adj_order == nil, tostring(bad_adj_order))

	local bad_province = nil
	for i = 1, #original.provinces do
		local a, b = original.provinces[i], rebuilt.provinces[i]
		if a.name ~= b.name or a.colour_index ~= b.colour_index
			or a.tile_count ~= b.tile_count
			or math.abs(a.cx - b.cx) > 1e-9 or math.abs(a.cy - b.cy) > 1e-9
			or #a.neighbours ~= #b.neighbours then
			bad_province = bad_province or (a.name .. " vs " .. b.name)
		end
	end
	check("provinces rederived", bad_province == nil, tostring(bad_province))

	local bad_adj = nil
	for i = 1, #original.adjacency do
		if #original.adjacency[i] ~= #rebuilt.adjacency[i] then bad_adj = i end
	end
	check("adjacency rederived", bad_adj == nil, tostring(bad_adj))

	check("content bounds match",
		math.abs(original.content.width - rebuilt.content.width) < 1e-9
		and math.abs(original.content.centre_y - rebuilt.content.centre_y) < 1e-9)
end

print("the projected view carries what the client reads")
do
	-- The client screens index this table directly (main/hud.gui_script,
	-- main/screens/empire.gui_script). Nothing type-checks that across the
	-- wire, so the shape is asserted here instead: a missing field shows up as
	-- a blank HUD on a device, three steps removed from the change that caused
	-- it.
	local st = require("realm.sim.state")
	local resolve = require("realm.sim.resolve")
	local view = require("realm.sim.view")
	local sim_path = require("realm.sim.path")
	local races = require("realm.sim.races")
	local commanders = require("realm.sim.commanders")

	local realm = gen.build(424242, { tile_count = 160 })
	local state = st.new(realm, {
		{ id = "a", name = "A", race = "kepler" },
		{ id = "b", name = "B", race = "vorn" },
	})
	local seat = state.players[1].seat
	resolve.turn(realm, state, {
		{ player = 1, kind = "move", commander = 1,
			route = { realm.adjacency[seat][1] } },
	})
	for _ = 1, 3 do resolve.turn(realm, state, {}) end

	local v = view.project(realm, state, 1)
	local required = {
		"turn", "you", "players", "tiles", "commanders", "contacts",
		"race", "seat", "provinces", "provinces_needed", "provinces_held", "rates",
	}
	local missing = {}
	for i = 1, #required do
		if v[required[i]] == nil then missing[#missing + 1] = required[i] end
	end
	check("the projection has every field the client reads", #missing == 0,
		table.concat(missing, ", "))

	for _, key in ipairs({ "tiles", "steps", "hops", "vision",
			"garrison_cap" }) do
		check("rates." .. key .. " is a number", type(v.rates[key]) == "number")
	end

	check("the roster reports each player's race",
		v.players[1].race == "kepler" and v.players[2].race == "vorn")
	check("and where each player's seat is",
		type(v.players[1].seat) == "number")

	local mine = v.tiles[tostring(seat)]
	check("your own seat is in the projection", mine ~= nil)
	check("...and says whose seat it is", mine and mine.seat_of == 1)
	check("...and that it is live rather than remembered", mine and mine.live == true)

	check("your commander travels in full",
		#v.commanders == 1 and v.commanders[1].route ~= nil
			and v.commanders[1].rank ~= nil and v.commanders[1].portrait ~= nil)
	check("and reports when it arrives, in turns",
		type(v.commanders[1].eta) == "number" and type(v.commanders[1].steps) == "number")
	-- Combat is two visible comparisons, so all four numbers have to reach the
	-- client: what a commander brings to each half, and what each half costs.
	check("and what it brings to each half of a fight",
		type(v.commanders[1].siege_power) == "number"
			and type(v.commanders[1].army_power) == "number")
	check("with the hold those came from",
		type(v.commanders[1].hold) == "table"
			and type(v.commanders[1].carried) == "number")
	-- The economy has to reach the client whole, or the sheet cannot price an
	-- embarkation without re-implementing the rules.
	check("the purse is on the wire", type(v.gold) == "number", v.gold)
	check("and what it earns each turn",
		type(v.rates.income) == "number" and v.rates.income > 0, v.rates.income)
	check("the unit catalogue is on the wire",
		type(v.units) == "table" and #v.units == 3, v.units and #v.units)
	check("and every type says what it is worth against each half", (function()
		for i = 1, #v.units do
			local spec = v.units[i]
			if type(spec.cost) ~= "number" then return false end
			if type(spec.fortification) ~= "number" then return false end
			if type(spec.army) ~= "number" then return false end
		end
		return true
	end)())
	check("a tile says what it pays its owner",
		type(mine.yield) == "number" and mine.yield > 0, mine.yield)
	check("and a city says what its dwellings have ready, by type",
		type(mine.available) == "table"
			and type(mine.available.escort) == "number", mine.available)
	-- A seat opens with Berths, so this one makes escorts and nothing else.
	check("what it cannot make is a zero, not a gap",
		mine.available.bombard == 0, mine.available.bombard)
	check("a garrison reaches the client whole, and counts as army", (function()
		local sim_units = require("realm.sim.units")
		state.tiles[seat].garrison = sim_units.normalise({ escort = 2 })
		local w = view.project(realm, state, 1)
		local seen = w.tiles[tostring(seat)]
		return seen.garrison and seen.garrison.escort == 2
			and seen.army >= sim_units.power(seen.garrison, sim_units.ARMY)
	end)())
	check("a commander says what it can carry as well as what it has",
		type(v.commanders[1].base_strength) == "number"
			and v.commanders[1].max_units > v.commanders[1].carried)

	check("the building catalogue is on the wire",
		type(v.buildings) == "table" and #v.buildings >= 4, v.buildings and #v.buildings)
	check("and every entry says what it is and what it costs", (function()
		for i = 1, #v.buildings do
			local b = v.buildings[i]
			if type(b.id) ~= "string" or type(b.name) ~= "string"
				or type(b.cost) ~= "number" then return false end
		end
		return true
	end)())
	check("a city says what is standing on it", type(mine.buildings) == "table")
	check("and how many commanders are allowed",
		type(v.rates.commander_cap) == "number" and v.rates.commander_cap >= 1)

	check("a tile somebody holds says what its walls are worth",
		type(mine.fortification) == "number", mine.fortification)
	check("and what army is standing on it", type(mine.army) == "number")
	check("unclaimed ground says neither, because there is nothing to take",
		(function()
			for _, sys in pairs(v.tiles) do
				if (sys.owner or 0) == 0
					and (sys.fortification ~= nil or sys.army ~= nil) then
					return false
				end
			end
			return true
		end)())
	check("tiles are keyed by string, never sparse integers",
		next(v.tiles) ~= nil and type(next(v.tiles)) == "string")

	-- Everything a player can see must be describable; nothing may arrive with
	-- an owner the roster cannot name.
	local bad = nil
	for id, sys in pairs(v.tiles) do
		if sys.owner and sys.owner > 0 and not v.players[sys.owner] then bad = id end
	end
	check("no tile names a player the roster does not have", bad == nil, bad)

	-- Every tile kind the client renders must be derivable from public data.
	local tiles_mod = require("realm.sim.tiles")
	local kinds = {}
	for id = 1, #realm.tiles do kinds[tiles_mod.kind(realm, id)] = true end
	-- The sim names a portrait; the client resolves it against
	-- main/portraits.atlas. Nothing connects the two but the string, and a
	-- mismatch is invisible offline - `ui.portrait` swallows a missing id on
	-- purpose, so the whole roster would quietly wear the fallback face.
	check("every portrait the sim can name exists in the atlas", (function()
		local atlas = io.open("main/portraits.atlas")
		if not atlas then return false, "no atlas" end
		local have = {}
		for line in atlas:lines() do
			local name = line:match('image:%s*"[^"]*/([^"/]+)%.png"')
			if name then have[name] = true end
		end
		atlas:close()
		local ids = races.ids()
		for i = 1, #ids do
			for n = 1, 40 do
				local id = commanders.portrait(n, nil, ids[i])
				if not have[id] then return false, id end
			end
		end
		return true
	end)())

	check("tile kinds are derivable client-side from the wire realm",
		kinds.city and kinds.holding and kinds.wilds)

	-- Reads an atlas file and returns the set of image names in it. Both map
	-- layers resolve art by *name* now - a sprite can no more be handed a UV
	-- rect than a GUI node can - so both joins have the same shape.
	local function atlas_images(path)
		local f = io.open(path)
		if not f then return nil end
		local have = {}
		for line in f:lines() do
			local name = line:match('image:%s*"[^"]*/([^"/]+)%.png"')
			if name then have[name] = true end
		end
		f:close()
		return have
	end

	-- The ground. main/theme.lua resolves a tile to a `tile_<biome>_<terrain>`
	-- image in main/tiles.atlas, generated by tools/import_tiles.py. Nothing
	-- connects the two but the string, and a miss is a hole in the map - so
	-- every pair the generator can actually produce has to be in the atlas,
	-- plus the sea, which no tile resolves to but the renderer still draws.
	check("every tile the theme can name exists in the tile atlas", (function()
		local theme = require("main.theme")
		local have = atlas_images("main/tiles.atlas")
		if not have then return false, "no main/tiles.atlas - run tools/import_tiles.py" end
		for id = 1, #realm.tiles do
			local name = theme.tile_for(realm, id)
			if not have[name] then return false, name end
		end
		if not have[theme.sea_tile()] then return false, theme.sea_tile() end
		return true
	end)())

	-- The same join for every *declared* pair, not just the ones this seed
	-- happened to roll. A biome that only appears on a cold map would otherwise
	-- be missing art nobody notices until somebody generates one.
	check("every declared biome x terrain pair is in the tile atlas", (function()
		local theme = require("main.theme")
		local have = atlas_images("main/tiles.atlas")
		if not have then return false, "no main/tiles.atlas" end
		for _, biome in ipairs(theme.BIOMES) do
			for terrain in pairs(theme.TILES) do
				local name = "tile_" .. biome .. "_" .. terrain
				if not have[name] then return false, name end
			end
		end
		return true
	end)())

	-- The glyphs on top. main/theme.lua names one, main/emoji.atlas holds it.
	-- `emoji_for` returns **nil** for open country on purpose - the hex
	-- underneath already says it is forest - so nil is the one answer that does
	-- not need an image, and anything else does.
	check("every glyph the theme can name exists in the emoji atlas", (function()
		local theme = require("main.theme")
		local have = atlas_images("main/emoji.atlas")
		if not have then return false, "no main/emoji.atlas - run tools/import_emoji.py" end
		local named = 0
		for id = 1, #realm.tiles do
			for _, seat in ipairs({ false, true }) do
				local name = theme.emoji_for(realm, id, seat)
				if name then
					named = named + 1
					if not have["emoji_" .. name] then return false, name end
				end
			end
		end
		-- A resolver that returned nil for everything would pass the loop above
		-- without drawing a single glyph.
		if named == 0 then return false, "the resolver named nothing at all" end
		return true
	end)())

	-- Every feature the generator can roll must be drawable, whether or not this
	-- seed rolled it. A holding with no glyph is ground the player cannot tell
	-- from open country while it quietly counts towards somebody's victory.
	check("every productive feature has a glyph", (function()
		local theme = require("main.theme")
		local terrain = require("realm.terrain")
		local have = atlas_images("main/emoji.atlas")
		if not have then return false, "no main/emoji.atlas" end
		local fake = { tiles = { { terrain = "plains", feature = "none", habitable = false } } }
		for i = 1, #terrain.FEATURES do
			local id = terrain.FEATURES[i].id
			if terrain.productive_feature(id) then
				fake.tiles[1].feature = id
				fake.tile_profiles = nil
				local name = theme.emoji_for(fake, 1, false)
				if not name or not have["emoji_" .. name] then return false, id end
			end
		end
		return true
	end)())

	-- The same join, for the *interface*. The tile sheet draws a unit as the
	-- emoji main/theme.lua's UNIT_EMOJI names, and main/emoji_ui.lua turns that
	-- into an atlas image id. Nothing connects the three but strings, and
	-- ui.emoji swallows a miss on purpose - so a mismatch would quietly draw an
	-- empty circle where a player's army is, which is the one thing on that
	-- card there is no other way to read.
	check("every unit type has an interface glyph", (function()
		local theme = require("main.theme")
		local units = require("realm.sim.units")
		local ok, atlas = pcall(require, "main.emoji_ui")
		if not ok then return false, "no main/emoji_ui.lua - run tools/import_emoji.py" end
		for i = 1, #units.CATALOGUE do
			local id = units.CATALOGUE[i].id
			if not theme.UNIT_EMOJI[id] then return false, "theme: " .. id end
			if not atlas[id] then return false, "atlas: " .. id end
		end
		return true
	end)())
end

print(failures == 0 and "\nALL WIRE TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
