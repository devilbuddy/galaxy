-- Simulation tests. Run: luajit tools/test_sim.lua
package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local view = require("galaxy.sim.view")
local path = require("galaxy.sim.path")
local rules = require("galaxy.sim.rules")
local systems = require("galaxy.sim.systems")
local buildings = require("galaxy.sim.buildings")
local tech = require("galaxy.sim.tech")
local races = require("galaxy.sim.races")
local modifiers = require("galaxy.sim.modifiers")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. tostring(detail or "")) end
end

local GALAXY = gen.build(424242, { star_count = 160 })
local LENGTHS = path.lane_lengths(GALAXY)

local function new_game(n, race)
	local players = {}
	for i = 1, n do players[i] = { id = "p" .. i, name = "P" .. i, race = race } end
	return st.new(GALAXY, players)
end

--- Find a system of a given kind, preferring one adjacent to `near`.
local function find(kind, near)
	if near then
		for _, id in ipairs(GALAXY.adjacency[near]) do
			if systems.kind(GALAXY, id) == kind then return id end
		end
	end
	for id = 1, #GALAXY.stars do
		if systems.kind(GALAXY, id) == kind then return id end
	end
	return nil
end

--- Give a player a system outright, as if they had already taken it.
local function grant(state, player, id, pop, ships)
	local sys = state.systems[id]
	sys.owner = player
	sys.population = pop or 0
	sys.ships = ships or 0
	return sys
end

--- A stable fingerprint of the whole mutable state.
local function digest(state)
	local parts = { "t" .. state.turn }
	for id = 1, #GALAXY.stars do
		local s = state.systems[id]
		if s.owner ~= 0 or s.ships ~= 0 or s.population ~= 0 then
			parts[#parts + 1] = string.format("%d:%d:%d:%d:%d/%d/%d",
				id, s.owner, s.population, s.ships,
				s.buildings.radar, s.buildings.fortress, s.buildings.shipyard)
		end
	end
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		parts[#parts + 1] = string.format("f%d:%d:%d:%d:%d:%d",
			f.id, f.owner, f.ships, f.at, math.floor(f.progress), #f.route)
	end
	for i = 1, #state.players do
		local p = state.players[i]
		local known = {}
		for k = 1, #tech.TECHS do
			if p.tech[tech.TECHS[k].id] then known[#known + 1] = tech.TECHS[k].id end
		end
		parts[#parts + 1] = string.format("p%d:%s:%d:%s", i, p.race, p.research,
			table.concat(known, ","))
	end
	return table.concat(parts, "|")
end

print("system types")
do
	local census = systems.census(GALAXY)
	check("the map has all three kinds of place",
		census.colony > 0 and census.outpost > 0 and census.waypoint > 0,
		string.format("%d/%d/%d", census.colony, census.outpost, census.waypoint))
	check("colonies are a minority, and terrain the majority",
		census.colony < census.waypoint + census.outpost, census.colony)

	-- The generator tops the count up so no seed is unplayable; see config.
	local floor_target = math.floor(#GALAXY.stars * 0.20 + 0.5)
	check("the colony floor is met", census.colony >= floor_target,
		census.colony .. " < " .. floor_target)

	local colony = find(systems.COLONY)
	local waypoint = find(systems.WAYPOINT)
	check("only a colony has a population ceiling",
		systems.capacity(GALAXY, colony) > 0 and systems.capacity(GALAXY, waypoint) == 0)
	check("a waypoint produces nothing at all",
		systems.output(GALAXY, waypoint, { population = 0 }) == 0
		and systems.research(GALAXY, waypoint, { population = 0 }) == 0)
	check("an outpost produces without anyone living there",
		systems.output(GALAXY, find(systems.OUTPOST), { population = 0 }) > 0)
end

print("setup")
do
	local s = new_game(4)
	local homes = {}
	for i = 1, 4 do
		local home = s.players[i].home
		check("home " .. i .. " is a colony", systems.is_colony(GALAXY, home))
		check("home " .. i .. " has room to expand",
			systems.colonies_within(GALAXY, home, rules.home_colony_hops)
				>= rules.home_colony_minimum)
		homes[home] = (homes[home] or 0) + 1
	end
	local shared = 0
	for _, c in pairs(homes) do if c > 1 then shared = shared + 1 end end
	check("no two players share a home", shared == 0)
	check("a home opens with a garrison, not a fleet",
		s.systems[s.players[1].home].ships == rules.start_ships and #s.fleets == 0)
end

print("growth and industry")
do
	local s = new_game(2)
	local home = s.players[1].home
	local before = s.systems[home].population
	res.turn(GALAXY, s, {}, LENGTHS)
	check("a colony grows toward capacity", s.systems[home].population > before)
	check("production lands in the garrison",
		s.systems[home].ships > rules.start_ships, s.systems[home].ships)

	for _ = 1, 90 do res.turn(GALAXY, s, {}, LENGTHS) end
	check("population saturates at capacity",
		s.systems[home].population == systems.capacity(GALAXY, home, modifiers.of(s.players[1])),
		s.systems[home].population)

	-- Terrain stays empty however long you hold it.
	local waypoint = find(systems.WAYPOINT, home)
	if waypoint then
		local w = new_game(2)
		grant(w, 1, waypoint, 0, 0)
		for _ = 1, 10 do res.turn(GALAXY, w, {}, LENGTHS) end
		check("a held waypoint never grows a population",
			w.systems[waypoint].population == 0)
		check("...and never builds a ship", w.systems[waypoint].ships == 0)
	end
end

print("buildings")
do
	local s = new_game(2)
	local home = s.players[1].home

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "build", at = home, building = "shipyard" },
	}, LENGTHS)
	check("a build order starts something", s.systems[home].building ~= nil)
	check("and it charges the world's own output",
		s.systems[home].building.paid > 0, s.systems[home].building.paid)

	local done = nil
	for _ = 1, 60 do
		local e = res.turn(GALAXY, s, {}, LENGTHS)
		for i = 1, #e do if e[i].kind == "building_complete" then done = e[i] end end
		if done then break end
	end
	check("it finishes", done and done.building == "shipyard", done and done.building)
	check("the level is recorded", s.systems[home].buildings.shipyard == 1)
	check("and the site is free again", s.systems[home].building == nil)

	-- A shipyard is worth having.
	local plain = new_game(2)
	local m = modifiers.of(plain.players[1])
	local bare = systems.output(GALAXY, home, { population = 100 }, m, buildings.zero())
	local yard = systems.output(GALAXY, home, { population = 100 }, m, { shipyard = 1 })
	check("a shipyard raises output", yard > bare, string.format("%.2f -> %.2f", bare, yard))

	-- Where things may go.
	local waypoint = find(systems.WAYPOINT)
	local outpost = find(systems.OUTPOST)
	check("nothing can be built on a waypoint",
		not buildings.allowed(GALAXY, waypoint, "radar"))
	check("military installations can go on an outpost",
		buildings.allowed(GALAXY, outpost, "radar")
		and buildings.allowed(GALAXY, outpost, "fortress"))
	check("a shipyard needs a colony",
		not buildings.allowed(GALAXY, outpost, "shipyard"))

	local bad = new_game(2)
	grant(bad, 1, outpost, 0, 0)
	local e = res.turn(GALAXY, bad, {
		{ player = 1, kind = "build", at = outpost, building = "shipyard" },
	}, LENGTHS)
	local refused = nil
	for i = 1, #e do if e[i].kind == "order_rejected" then refused = e[i] end end
	check("and says so when refused",
		refused and refused.reason == "needs a colony", refused and refused.reason)
end

print("research")
do
	local s = new_game(2)
	local me = s.players[1]

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "research", tech = "warp_lattice" },
	}, LENGTHS)
	local rejected = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" and ev[i].tech then rejected = ev[i] end end
	check("a tech with unmet prerequisites is refused",
		rejected and rejected.reason == "prerequisites not met", rejected and rejected.reason)
	check("and nothing was set as the target", me.researching == nil)

	res.turn(GALAXY, s, { { player = 1, kind = "research", tech = "survey_network" } }, LENGTHS)
	check("a tier-one tech becomes the target", me.researching == "survey_network")
	check("research pools", me.research > 0, me.research)

	local completed = nil
	for _ = 1, 400 do
		local e = res.turn(GALAXY, s, {}, LENGTHS)
		for i = 1, #e do if e[i].kind == "research_complete" then completed = e[i] end end
		if completed then break end
	end
	check("it eventually completes", completed and completed.tech == "survey_network")
	check("completing clears the target", me.researching == nil)
	check("the tech is recorded", me.tech.survey_network == true)

	local mods = modifiers.of(me)
	check("Survey Network widens vision", mods.vision == 1, mods.vision)

	local avail = {}
	for _, id in ipairs(tech.available(me.tech)) do avail[id] = true end
	check("its dependants unlock", avail.orbital_yards and avail.xeno_archives)
	check("the tier above stays locked", not avail.bastion_protocols)
end

print("fleets")
do
	local s = new_game(2)
	local home = s.players[1].home
	local near = GALAXY.adjacency[home][1]
	s.systems[home].ships = 60

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 20, route = { near } },
	}, LENGTHS)
	check("a launch takes ships out of the garrison", s.systems[home].ships <= 40 + 8)
	check("and creates exactly one fleet", #s.fleets == 1)
	local fleet = s.fleets[1]
	check("the force is named for its commander", type(fleet.name) == "string"
		and fleet.name ~= "" and not fleet.name:find("Fleet"), fleet.name)
	check("who starts green", fleet.level == 1 and fleet.xp == 0)
	check("it carries the ships it was given", fleet.ships == 20, fleet.ships)

	local arrived = false
	for _ = 1, 8 do
		if s.systems[near].owner == 1 then arrived = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("it reaches an adjacent system", arrived)
	check("and it is still a fleet afterwards", #s.fleets == 1 and s.fleets[1].ships > 0)
	check("...parked, not moving", st.is_parked(s.fleets[1]))

	-- Standing down returns it to the pool.
	local id = s.fleets[1].id
	local ships = s.fleets[1].ships
	local before = s.systems[near].ships
	res.turn(GALAXY, s, { { player = 1, kind = "garrison", fleet = id } }, LENGTHS)
	check("standing down returns the ships", s.systems[near].ships >= before + ships)
	check("and the fleet is gone", #s.fleets == 0)
end

print("a move can detach part of a fleet")
do
	local s = new_game(2)
	local home = s.players[1].home
	local a = GALAXY.adjacency[home][1]
	local b = GALAXY.adjacency[home][2] or a
	s.systems[home].ships = 100
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 60, route = {} },
	}, LENGTHS)
	-- An empty route is refused; launch straight at a neighbour instead.
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 60, route = { a } },
	}, LENGTHS)
	local first = s.fleets[1]
	check("one fleet under way", first ~= nil and first.ships == 60, first and first.ships)

	-- Wait for it to park, then send half of it on.
	for _ = 1, 8 do
		if st.is_parked(s.fleets[1]) then break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	local parked = s.fleets[1]
	local before = parked.ships
	res.turn(GALAXY, s, {
		{ player = 1, kind = "move", fleet = parked.id, ships = 20, route = { b } },
	}, LENGTHS)
	check("a detachment becomes its own force", #s.fleets == 2, #s.fleets)

	-- Conservation is no longer testable as "the fleets still add to 60": the
	-- worlds produce every turn and a parked commander draws from the garrison
	-- (resupply), so both numbers move. What must hold is that the detachment
	-- took its ships *from the parent* rather than inventing them.
	local detached, parent = nil, nil
	for i = 1, #s.fleets do
		if s.fleets[i].id == parked.id then parent = s.fleets[i]
		else detached = s.fleets[i] end
	end
	check("the detachment carries what it was given", detached and detached.ships == 20,
		detached and detached.ships)
	-- Not "down by exactly 20": the parent is parked on a world it owns, so
	-- resupply tops it back up from that garrison in the same turn. The
	-- detachment is what this is testing; that it cost the parent something is
	-- all that can be asserted without disabling half the turn.
	check("and the parent is smaller for it", parent and parent.ships < before,
		parent and (before - parent.ships))
end

print("forces stay separate")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 120
	local a = GALAXY.adjacency[home][1]
	local b = nil
	for _, id in ipairs(GALAXY.adjacency[a]) do if id ~= home then b = id break end end

	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 20, route = { b } },
		{ player = 1, kind = "launch", at = home, ships = 20, route = { b } },
	}, LENGTHS)
	check("two launches make two forces", #s.fleets == 2, #s.fleets)

	for _ = 1, 12 do res.turn(GALAXY, s, {}, LENGTHS) end
	-- Co-located forces used to be folded into one to keep the list readable.
	-- Under a commander cap the list cannot get long enough to need it, and
	-- merging would quietly destroy an officer for parking next to a colleague.
	check("arriving together they stay two", #s.fleets == 2, #s.fleets)
	check("with different commanders", s.fleets[1].name ~= s.fleets[2].name)
end

print("routes")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 40

	-- Multiple waypoints expand into one lane-by-lane route.
	local a = GALAXY.adjacency[home][1]
	local b = nil
	for _, id in ipairs(GALAXY.adjacency[a]) do if id ~= home then b = id break end end
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 20, route = { a, b } },
	}, LENGTHS)
	check("a launch with two waypoints is accepted", #s.fleets == 1, #s.fleets)
	local reached = false
	for _ = 1, 12 do
		if s.fleets[1] and s.fleets[1].at == b and st.is_parked(s.fleets[1]) then
			reached = true
			break
		end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("and the fleet visits both in turn", reached)

	-- ...and an impossible one is refused with a reason.
	local e = res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 5, route = { 999999 } },
	}, LENGTHS)
	local refused = nil
	for i = 1, #e do if e[i].kind == "order_rejected" then refused = e[i] end end
	check("an unreachable waypoint is refused", refused ~= nil,
		refused and refused.reason)
	check("the rejection is private", refused and #refused.visible_to == 1)
end

print("movement takes terrain and stops at a border")
do
	-- A long route through neutral space claims everything it passes.
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 200
	local chain, at = {}, home
	for _ = 1, 3 do
		local nxt = nil
		for _, id in ipairs(GALAXY.adjacency[at]) do
			if s.systems[id].owner == 0 then nxt = id break end
		end
		if not nxt then break end
		chain[#chain + 1] = nxt
		at = nxt
	end
	if #chain >= 2 then
		res.turn(GALAXY, s, {
			{ player = 1, kind = "launch", at = home, ships = 150, route = { chain[#chain] } },
		}, LENGTHS)
		for _ = 1, 12 do res.turn(GALAXY, s, {}, LENGTHS) end
		local taken = 0
		for i = 1, #chain do
			if s.systems[chain[i]].owner == 1 then taken = taken + 1 end
		end
		check("a route through neutral space sweeps it up", taken == #chain,
			taken .. " of " .. #chain)
	end

	-- A hostile system stops a fleet dead.
	local h = new_game(2)
	local mine = h.players[1].home
	local block = GALAXY.adjacency[mine][1]
	local beyond = nil
	for _, id in ipairs(GALAXY.adjacency[block]) do if id ~= mine then beyond = id break end end
	grant(h, 2, block, 0, 500)
	h.systems[mine].ships = 30
	res.turn(GALAXY, h, {
		{ player = 1, kind = "launch", at = mine, ships = 20, route = { beyond } },
	}, LENGTHS)
	for _ = 1, 6 do res.turn(GALAXY, h, {}, LENGTHS) end
	check("a defended border blocks a route", h.systems[beyond].owner ~= 1)
end

print("interception")
do
	-- Commanders now move slower than a typical lane is long, so this is
	-- reachable at the real speed - but only on lanes long enough, which varies
	-- by seed. Slowing them right down keeps the test about the rule rather
	-- than about which lane the generator happened to draw.
	local real_speed = rules.commander_speed
	rules.commander_speed = 20

	local s = new_game(2)
	local a = s.players[1].home
	local b = GALAXY.adjacency[a][1]
	grant(s, 2, b, 0, 100)
	s.systems[a].ships = 100

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = a, ships = 60, route = { b } },
		{ player = 2, kind = "launch", at = b, ships = 60, route = { a } },
	}, LENGTHS)
	local met = nil
	for _ = 1, 5 do
		for i = 1, #ev do if ev[i].kind == "intercepted" then met = ev[i] end end
		if met then break end
		ev = res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("hostile fleets meeting in a lane fight there", met ~= nil)
	check("the engagement names the lane", met and met.a and met.b)
	check("and one side is destroyed", met and met.survivors > 0)

	rules.commander_speed = real_speed
end

print("battles, garrisons and fortifications")
do
	-- An empty world is not free: its own guns have to be beaten.
	local s = new_game(2)
	local target = nil
	for id = 1, #GALAXY.stars do
		if systems.is_colony(GALAXY, id) and s.systems[id].owner == 0 then target = id break end
	end
	grant(s, 2, target, 120, 0)
	local defence = systems.defence(GALAXY, target, s.systems[target], buildings.zero())
	check("a populated world defends itself with nothing stationed", defence > 0, defence)

	-- A fortress is worth a lot of ships.
	local fortified = systems.defence(GALAXY, target, s.systems[target], { fortress = 2 })
	check("a fortress adds to that", fortified > defence + 50,
		string.format("%.0f -> %.0f", defence, fortified))

	-- Overwhelming force takes it, and the buildings survive.
	local attacker = GALAXY.adjacency[target][1]
	grant(s, 1, attacker, 0, 4000)
	s.systems[target].buildings.fortress = 1
	s.systems[target].buildings.radar = 2
	local pop_before = s.systems[target].population
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = attacker, ships = 4000, route = { target } },
	}, LENGTHS)
	local captured = false
	for _ = 1, 6 do
		if s.systems[target].owner == 1 then captured = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("an overwhelming attack captures a fortified world", captured)
	check("buildings survive the capture",
		s.systems[target].buildings.fortress == 1 and s.systems[target].buildings.radar == 2)
	check("but the population does not", s.systems[target].population < pop_before,
		pop_before .. " -> " .. s.systems[target].population)

	-- The reverse: a token attack against fortifications fails.
	local s2 = new_game(2)
	local t2 = target
	grant(s2, 2, t2, 150, 200)
	s2.systems[t2].buildings.fortress = 3
	local a2 = GALAXY.adjacency[t2][1]
	grant(s2, 1, a2, 0, 30)
	res.turn(GALAXY, s2, {
		{ player = 1, kind = "launch", at = a2, ships = 30, route = { t2 } },
	}, LENGTHS)
	for _ = 1, 6 do res.turn(GALAXY, s2, {}, LENGTHS) end
	check("a hopeless attack does not capture", s2.systems[t2].owner == 2)
	check("and the planet's guns are not shot down",
		s2.systems[t2].buildings.fortress == 3)
end

print("detection is a range")
do
	local plain = new_game(2)
	local radar = new_game(2)
	local home = radar.players[1].home
	radar.systems[home].buildings.radar = 2

	local a = view.visible_systems(GALAXY, plain, 1)
	local b = view.visible_systems(GALAXY, radar, 1)
	local na, nb = 0, 0
	for _ in pairs(a) do na = na + 1 end
	for _ in pairs(b) do nb = nb + 1 end
	check("radar sees further", nb > na, na .. " -> " .. nb)
	for id in pairs(a) do
		if not b[id] then check("and never sees less", false, "lost " .. id) break end
	end

	-- Technology stacks on top of the building.
	local teched = new_game(2)
	teched.players[1].tech.survey_network = true
	local c = view.visible_systems(GALAXY, teched, 1)
	local nc = 0
	for _ in pairs(c) do nc = nc + 1 end
	check("a vision technology stacks with it", nc > na, na .. " -> " .. nc)
end

print("enemy fleets are seen where you have eyes")
do
	local s = new_game(2)
	local mine = s.players[1].home
	local border = GALAXY.adjacency[mine][1]
	-- Placed rather than launched: a fleet sent at a home world fights on
	-- arrival, and what is under test here is detection, not combat.
	grant(s, 2, border, 0, 0)
	st.add_fleet(s, 2, border, 60)

	local v = view.project(GALAXY, s, 1)
	check("an enemy fleet in range shows up as a contact", #v.contacts > 0, #v.contacts)
	check("its strength is reported", v.contacts[1] and v.contacts[1].ships == 60)
	check("but not its orders", v.contacts[1] and v.contacts[1].route == nil)
	check("nor which fleet it is", v.contacts[1] and v.contacts[1].name == nil)

	-- ...and one on the far side of the map is not.
	local far = s.players[2].home
	local s2 = new_game(2)
	st.add_fleet(s2, 2, far, 50)
	local v2 = view.project(GALAXY, s2, 1)
	local sees_far = false
	for i = 1, #v2.contacts do
		if v2.contacts[i].at == far then sees_far = true end
	end
	check("a distant enemy is invisible", not sees_far)
	check("and their home is not in the projection", v2.systems[tostring(far)] == nil)
end

print("races differ on the new axis")
do
	check("every declared race resolves", races.exists("cartel") and races.exists("silicate"))
	check("an unknown race falls back", races.by_id("clangers").id == races.DEFAULT)
	local cartel = modifiers.of({ race = "cartel" })
	local silicate = modifiers.of({ race = "silicate" })
	check("the fast race moves further", cartel.speed_scale > silicate.speed_scale)
	check("the fortifying race fortifies harder", silicate.fortress > cartel.fortress)
	check("nobody is strictly better than the baseline",
		cartel.defence < modifiers.of(nil).defence
		and silicate.growth < modifiers.of(nil).growth)
end

print("commanders")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 2000
	local a = GALAXY.adjacency[home][1]

	-- The cap is the shape of the game: four fronts, no more.
	local orders = {}
	for _ = 1, rules.commander_cap + 2 do
		orders[#orders + 1] = { player = 1, kind = "launch", at = home, ships = 50, route = { a } }
	end
	local ev = res.turn(GALAXY, s, orders, LENGTHS)
	check("only as many forces as there are commanders", #s.fleets == rules.commander_cap,
		#s.fleets)
	local refused = false
	for i = 1, #ev do
		if ev[i].kind == "order_rejected" and ev[i].reason == "no commander to spare" then
			refused = true
		end
	end
	check("and the rest are refused with a reason", refused)

	-- A commander leads what their rank allows; the rest waits in the garrison.
	local s2 = new_game(2)
	local h2 = s2.players[1].home
	s2.systems[h2].ships = 2000
	local n2 = GALAXY.adjacency[h2][1]
	res.turn(GALAXY, s2, {
		{ player = 1, kind = "launch", at = h2, ships = 2000, route = { n2 } },
	}, LENGTHS)
	local led = s2.fleets[1].ships
	check("a green commander leads only what they can", led <= rules.command_base, led)
	check("and the rest stays behind", s2.systems[h2].ships > 0, s2.systems[h2].ships)
end

print("commanders improve, and are not thrown away")
do
	local cmd = require("galaxy.sim.commanders")
	check("a green officer is a Captain", cmd.rank(1) == "Captain")
	check("a veteran is not", cmd.rank(rules.commander_max_level) ~= "Captain")
	check("levels need more each time",
		cmd.xp_for_level(3) - cmd.xp_for_level(2) > cmd.xp_for_level(2) - cmd.xp_for_level(1))
	check("experience never exceeds the ceiling",
		cmd.level_for_xp(cmd.xp_for_level(rules.commander_max_level) * 100)
			== rules.commander_max_level)

	local officer = { level = 1, xp = 0 }
	local gained = cmd.award(officer, cmd.xp_for_level(3))
	check("enough experience promotes", officer.level == 3, officer.level)
	check("and reports how far", gained == 2, gained)
	check("a veteran leads more", cmd.command({ level = 3 }) > cmd.command({ level = 1 }))
	check("moves faster", cmd.speed({ level = 3 }) > cmd.speed({ level = 1 }))
	check("and fights better", cmd.tactics({ level = 3 }) > cmd.tactics({ level = 1 }))

	cmd.demote(officer)
	check("a defeat costs a rank, not the officer", officer.level == 2, officer.level)
	check("and the experience for it", officer.xp == cmd.xp_for_level(2))
end

print("a beaten commander scatters rather than dying")
do
	local s = new_game(2)
	local home = s.players[1].home
	local target = GALAXY.adjacency[home][1]
	-- Somewhere hopeless to attack.
	grant(s, 2, target, 200, 4000)
	s.systems[home].ships = 300

	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 200, route = { target } },
	}, LENGTHS)
	local officer = s.fleets[1]
	local name = officer and officer.name

	local scattered = nil
	for _ = 1, 10 do
		local ev = res.turn(GALAXY, s, {}, LENGTHS)
		for i = 1, #ev do
			if ev[i].kind == "commander_scattered" then scattered = ev[i] end
		end
		if scattered then break end
	end
	check("the officer survives the defeat", scattered ~= nil)
	check("it is the same officer", scattered and scattered.name == name,
		scattered and scattered.name)
	check("and they fall back somewhere held", scattered
		and s.systems[scattered.at].owner == 1)
	local still_there = false
	for i = 1, #s.fleets do
		if s.fleets[i].name == name then still_there = true end
	end
	check("still on the roster", still_there)
end

print("standing down retires an officer to the reserve")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 400
	local a = GALAXY.adjacency[home][1]

	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 100, route = { a } },
	}, LENGTHS)
	local officer = s.fleets[1]
	officer.level = 5
	officer.xp = require("galaxy.sim.commanders").xp_for_level(5)
	local name = officer.name

	-- Bring them home and stand them down.
	officer.route = {}
	officer.at = home
	officer.progress = 0
	res.turn(GALAXY, s, {
		{ player = 1, kind = "garrison", fleet = officer.id },
	}, LENGTHS)
	check("the force is gone", #s.fleets == 0, #s.fleets)
	check("but the officer is on the reserve list",
		s.players[1].reserve and #s.players[1].reserve == 1)
	check("with their rank intact", s.players[1].reserve
		and s.players[1].reserve[1].level == 5)

	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 100, route = { a } },
	}, LENGTHS)
	check("and they are the one recalled", s.fleets[1] and s.fleets[1].name == name,
		s.fleets[1] and s.fleets[1].name)
	check("still at their rank", s.fleets[1] and s.fleets[1].level == 5,
		s.fleets[1] and s.fleets[1].level)
end

print("a parked commander draws from the garrison")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 60
	local a = GALAXY.adjacency[home][1]
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 10, route = { a } },
	}, LENGTHS)
	local officer = s.fleets[1]
	officer.route = {}
	officer.progress = 0
	officer.at = home
	local before = officer.ships
	s.systems[home].ships = 200
	res.turn(GALAXY, s, {}, LENGTHS)
	check("a force on one of your worlds reinforces", officer.ships > before,
		officer.ships)
	check("but never past what its commander can lead",
		officer.ships <= require("galaxy.sim.commanders").command(officer,
			modifiers.of(s.players[1])), officer.ships)
end

print("regions are the objective")
do
	local regions = require("galaxy.sim.regions")
	local s = new_game(2)
	check("the map is carved into regions", #GALAXY.regions > 1, #GALAXY.regions)
	check("winning needs more than one", regions.needed(GALAXY) >= 2)

	local held = regions.control(GALAXY, s)
	check("nobody holds one at the opening", (regions.tally(GALAXY, s, held)[1] or 0) == 0)

	-- Hand player 1 everything that counts in one region and nothing else.
	local target = GALAXY.stars[s.players[1].home].region
	local counted = 0
	for id = 1, #GALAXY.stars do
		if GALAXY.stars[id].region == target and regions.counts(GALAXY, id) then
			s.systems[id].owner = 1
			counted = counted + 1
		end
	end
	held = regions.control(GALAXY, s)
	check("holding what counts takes the region", held[target] == 1, held[target])
	check("waypoints are not what counts", counted < GALAXY.regions[target].star_count)

	-- Half of it is not enough: a region changing hands has to be news.
	local given_back = 0
	for id = 1, #GALAXY.stars do
		if GALAXY.stars[id].region == target and regions.counts(GALAXY, id)
			and given_back < math.ceil(counted / 2) then
			s.systems[id].owner = 0
			given_back = given_back + 1
		end
	end
	held = regions.control(GALAXY, s)
	check("a bare half does not hold it", held[target] == 0, held[target])
end

print("state survives a round trip")
do
	local s = new_game(2)
	local home = s.players[1].home
	s.systems[home].ships = 50
	s.players[1].tech.ion_drive = true
	s.players[1].researching = "fleet_logistics"
	res.turn(GALAXY, s, {
		{ player = 1, kind = "launch", at = home, ships = 20,
			route = { GALAXY.adjacency[home][1] } },
		{ player = 1, kind = "build", at = home, building = "radar" },
	}, LENGTHS)

	-- Imitate what Nakama storage does: numbers come back as strings, a set
	-- arrives as a list, and new fields are simply absent.
	local wire = {
		seed = s.seed, turn = s.turn, players = {}, systems = s.systems,
		fleets = {}, next_fleet_id = tostring(s.next_fleet_id),
		knowledge = s.knowledge,
	}
	for i = 1, #s.players do
		local p = s.players[i]
		wire.players[i] = {
			id = p.id, name = p.name, race = p.race, home = p.home, alive = p.alive,
			research = tostring(p.research),
			tech = { "ion_drive" },
			researching = p.researching,
			next_commander_number = tostring(p.next_commander_number),
		}
	end
	for i = 1, #s.fleets do
		local f = s.fleets[i]
		wire.fleets[i] = {
			id = tostring(f.id), owner = f.owner, name = f.name,
			ships = tostring(f.ships), at = tostring(f.at),
			progress = tostring(f.progress), route = f.route,
		}
	end
	for _, sys in pairs(wire.systems) do sys.ships = tostring(sys.ships) end

	local fixed = st.migrate(wire)
	check("technology survives arriving as a list", fixed.players[1].tech.ion_drive == true)
	check("stringified numbers are re-typed",
		fixed.players[1].research == s.players[1].research)
	check("garrisons are re-typed", type(fixed.systems[home].ships) == "number")
	check("fleets are re-typed",
		type(fixed.fleets[1].ships) == "number" and type(fixed.fleets[1].at) == "number")
	check("building levels survive", fixed.systems[home].buildings.radar ~= nil)
	local ok, err = pcall(res.turn, GALAXY, fixed, {}, LENGTHS)
	check("and a repaired state resolves another turn", ok, err)
end

print("determinism")
do
	local ids = races.ids()
	local orders_for = function(state, turn)
		local out = {}
		for i = 1, #state.players do
			local me = state.players[i]
			if not me.researching then
				local avail = tech.available(me.tech)
				if #avail > 0 then
					out[#out + 1] = { player = i, kind = "research",
						tech = avail[(turn % #avail) + 1] }
				end
			end
			local owned = st.owned_by(state, i)
			if #owned > 0 then
				local from = owned[(turn % #owned) + 1]
				local sys = state.systems[from]
				if turn % 5 == 0 and not sys.building then
					out[#out + 1] = { player = i, kind = "build",
						at = from, building = "radar" }
				end
				local nb = GALAXY.adjacency[from]
				if #nb > 0 and sys.ships > 4 then
					out[#out + 1] = { player = i, kind = "launch", at = from,
						ships = math.floor(sys.ships / 2),
						route = { nb[(turn % #nb) + 1] } }
				end
			end
			for f = 1, #state.fleets do
				local fleet = state.fleets[f]
				if fleet.owner == i and st.is_parked(fleet) and turn % 3 == 0 then
					out[#out + 1] = { player = i, kind = "garrison", fleet = fleet.id }
				end
			end
		end
		return out
	end

	local function play(turns)
		local s = new_game(4)
		for i = 1, 4 do s.players[i].race = ids[i] end
		for t = 1, turns do res.turn(GALAXY, s, orders_for(s, t), LENGTHS) end
		return digest(s)
	end

	local a, b = play(50), play(50)
	check("same seed and orders reproduce the same state exactly", a == b)
	check("the game actually progressed", #a > 400, "digest length " .. #a)
end

print(failures == 0 and "\nALL SIM TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
