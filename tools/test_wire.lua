-- Round-trip test for the client/server wire format.
-- Run: luajit tools/test_wire.lua
package.path = "./?.lua;" .. package.path
local gen = require("galaxy.generate")
local wire = require("galaxy.wire")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. (detail or "")) end
end

for _, seed in ipairs({ 1, 424242, 1337 }) do
	local original = gen.build(seed)
	local rebuilt = wire.decode(wire.encode(original))
	print("seed " .. seed)

	check("star count", #rebuilt.stars == #original.stars)
	check("lane count", #rebuilt.lanes == #original.lanes)
	check("region count", #rebuilt.regions == #original.regions)
	check("world size", rebuilt.world_size == original.world_size)

	local worst_pos, bad_field = 0, nil
	for i = 1, #original.stars do
		local a, b = original.stars[i], rebuilt.stars[i]
		worst_pos = math.max(worst_pos, math.abs(a.x - b.x), math.abs(a.y - b.y))
		if a.name ~= b.name or a.class ~= b.class or a.feature ~= b.feature
			or a.region ~= b.region or a.habitable ~= b.habitable
			or a.class_label ~= b.class_label or a.radius ~= b.radius then
			bad_field = bad_field or ("star " .. i .. " (" .. a.name .. ")")
		end
	end
	check("star fields survive the round trip", bad_field == nil, tostring(bad_field))
	check("positions exact", worst_pos == 0, "worst delta " .. worst_pos)

	local bad_lane = nil
	for i = 1, #original.lanes do
		local a, b = original.lanes[i], rebuilt.lanes[i]
		if a.a ~= b.a or a.b ~= b.b or a.border ~= b.border then bad_lane = i end
	end
	check("lanes and border flags rederived", bad_lane == nil, tostring(bad_lane))

	local bad_region = nil
	for i = 1, #original.regions do
		local a, b = original.regions[i], rebuilt.regions[i]
		if a.name ~= b.name or a.colour_index ~= b.colour_index
			or a.star_count ~= b.star_count
			or math.abs(a.cx - b.cx) > 1e-9 or math.abs(a.cy - b.cy) > 1e-9
			or #a.neighbours ~= #b.neighbours then
			bad_region = bad_region or (a.name .. " vs " .. b.name)
		end
	end
	check("regions rederived", bad_region == nil, tostring(bad_region))

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
	local st = require("galaxy.sim.state")
	local resolve = require("galaxy.sim.resolve")
	local view = require("galaxy.sim.view")
	local sim_path = require("galaxy.sim.path")
	local races = require("galaxy.sim.races")
	local commanders = require("galaxy.sim.commanders")

	local galaxy = gen.build(424242, { star_count = 160 })
	local lengths = sim_path.lane_lengths(galaxy)
	local state = st.new(galaxy, {
		{ id = "a", name = "A", race = "kepler" },
		{ id = "b", name = "B", race = "vorn" },
	})
	local capital = state.players[1].capital
	resolve.turn(galaxy, state, {
		{ player = 1, kind = "move", captain = 1,
			route = { galaxy.adjacency[capital][1] } },
	}, lengths)
	for _ = 1, 3 do resolve.turn(galaxy, state, {}, lengths) end

	local v = view.project(galaxy, state, 1)
	local required = {
		"turn", "you", "players", "systems", "captains", "contacts",
		"race", "capital", "regions", "regions_needed", "regions_held", "rates",
	}
	local missing = {}
	for i = 1, #required do
		if v[required[i]] == nil then missing[#missing + 1] = required[i] end
	end
	check("the projection has every field the client reads", #missing == 0,
		table.concat(missing, ", "))

	for _, key in ipairs({ "systems", "steps", "hops", "vision" }) do
		check("rates." .. key .. " is a number", type(v.rates[key]) == "number")
	end

	check("the roster reports each player's race",
		v.players[1].race == "kepler" and v.players[2].race == "vorn")
	check("and where each player's capital is",
		type(v.players[1].capital) == "number")

	local mine = v.systems[tostring(capital)]
	check("your own capital is in the projection", mine ~= nil)
	check("...and says whose capital it is", mine and mine.capital_of == 1)
	check("...and that it is live rather than remembered", mine and mine.live == true)

	check("your captain travels in full",
		#v.captains == 1 and v.captains[1].route ~= nil
			and v.captains[1].rank ~= nil and v.captains[1].portrait ~= nil)
	check("and reports when it arrives, in turns",
		type(v.captains[1].eta) == "number" and type(v.captains[1].steps) == "number")
	-- Combat is one visible comparison, so both sides of it have to reach the
	-- client: what a captain can spend, and what a system costs to take.
	check("and what it can spend, against what it could spend at full",
		type(v.captains[1].strength) == "number"
			and type(v.captains[1].max_strength) == "number")
	check("a system somebody holds says what it defends at",
		type(mine.defence) == "number", mine.defence)
	check("and unclaimed ground says nothing, because there is nothing to take",
		(function()
			for _, sys in pairs(v.systems) do
				if (sys.owner or 0) == 0 and sys.defence ~= nil then return false end
			end
			return true
		end)())
	check("systems are keyed by string, never sparse integers",
		next(v.systems) ~= nil and type(next(v.systems)) == "string")

	-- Everything a player can see must be describable; nothing may arrive with
	-- an owner the roster cannot name.
	local bad = nil
	for id, sys in pairs(v.systems) do
		if sys.owner and sys.owner > 0 and not v.players[sys.owner] then bad = id end
	end
	check("no system names a player the roster does not have", bad == nil, bad)

	-- Every system kind the client renders must be derivable from public data.
	local systems_mod = require("galaxy.sim.systems")
	local kinds = {}
	for id = 1, #galaxy.stars do kinds[systems_mod.kind(galaxy, id)] = true end
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

	check("system kinds are derivable client-side from the wire galaxy",
		kinds.colony and kinds.outpost and kinds.waypoint)
end

print(failures == 0 and "\nALL WIRE TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
