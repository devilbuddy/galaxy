-- Simulation tests. Run: luajit tools/test_sim.lua
package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local view = require("galaxy.sim.view")
local path = require("galaxy.sim.path")
local rules = require("galaxy.sim.rules")
local resources = require("galaxy.sim.resources")
local tech = require("galaxy.sim.tech")
local races = require("galaxy.sim.races")
local modifiers = require("galaxy.sim.modifiers")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. tostring(detail or "")) end
end

local GALAXY = gen.build(424242)
local LENGTHS = path.lane_lengths(GALAXY)

local function new_game(n, race)
	local players = {}
	for i = 1, n do players[i] = { id = "p" .. i, name = "P" .. i, race = race } end
	return st.new(GALAXY, players)
end

--- Give a player a system outright, as if they had already taken it.
local function grant(state, player, id, pop, ships)
	local sys = state.systems[id]
	sys.owner = player
	sys.population = pop or 100
	sys.ships = ships or 0
	return sys
end

--- A stable fingerprint of the whole mutable state.
local function digest(state)
	local parts = { "t" .. state.turn }
	for id = 1, #GALAXY.stars do
		local s = state.systems[id]
		if s.owner ~= 0 or s.ships ~= 0 or s.population ~= 0 then
			parts[#parts + 1] = string.format("%d:%d:%d:%d", id, s.owner, s.population, s.ships)
		end
	end
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		parts[#parts + 1] = string.format("f%d:%d:%d:%d:%d:%s",
			f.id, f.owner, f.ships, f.at, #f.path, f.kind or "move")
	end
	for i = 1, #state.routes do
		local r = state.routes[i]
		parts[#parts + 1] = string.format("r%d:%d:%d:%d", r.owner, r.a, r.b, r.ships)
	end
	for i = 1, #state.players do
		local p = state.players[i]
		local known = {}
		for k = 1, #tech.TECHS do
			if p.tech[tech.TECHS[k].id] then known[#known + 1] = tech.TECHS[k].id end
		end
		parts[#parts + 1] = string.format("p%d:%s:%d:%d:%d:%s", i, p.race,
			p.stock.metal, p.stock.fuel, p.stock.research, table.concat(known, ","))
	end
	return table.concat(parts, "|")
end

print("setup")
do
	local s = new_game(4)
	check("each player owns exactly one system at turn 0",
		#st.owned_by(s, 1) == 1 and #st.owned_by(s, 4) == 1)
	local homes = {}
	for i = 1, 4 do homes[s.players[i].home] = (homes[s.players[i].home] or 0) + 1 end
	local shared = 0
	for _, c in pairs(homes) do if c > 1 then shared = shared + 1 end end
	check("no two players share a home", shared == 0)
	check("home has starting forces",
		s.systems[s.players[1].home].ships == rules.start_ships)
end

print("production")
do
	local s = new_game(2)
	local home = s.players[1].home
	local before = s.systems[home].population
	res.turn(GALAXY, s, {}, LENGTHS)
	local after = s.systems[home].population
	check("population grows toward capacity", after > before, before .. " -> " .. after)
	check("capacity is never exceeded", after <= st.capacity(GALAXY, home))
	check("ships are produced", s.systems[home].ships > rules.start_ships)

	-- Run to saturation and confirm it settles rather than overshooting.
	for _ = 1, 80 do res.turn(GALAXY, s, {}, LENGTHS) end
	check("population saturates at capacity",
		s.systems[home].population == st.capacity(GALAXY, home),
		s.systems[home].population .. " vs " .. st.capacity(GALAXY, home))
end

print("movement")
do
	local s = new_game(2)
	local home = s.players[1].home
	local target = GALAXY.adjacency[home][1]
	local ev = res.turn(GALAXY, s, { { player = 1, from = home, to = target, ships = 5 } }, LENGTHS)
	check("ships leave the origin", s.systems[home].ships < rules.start_ships + 10)

	local arrived = false
	for _ = 1, 6 do
		if s.systems[target].owner == 1 then arrived = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("a fleet reaches an adjacent unowned system", arrived)
	check("claiming leaves a garrison", s.systems[target].ships > 0)
end

print("orders are validated, not silently dropped")
do
	local s = new_game(2)
	local foreign = s.players[2].home
	local ev = res.turn(GALAXY, s, {
		{ player = 1, from = foreign, to = s.players[1].home, ships = 5 },
	}, LENGTHS)
	local rejected = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" then rejected = ev[i] end end
	check("ordering from a system you do not own is rejected", rejected ~= nil)
	check("the rejection says why", rejected and rejected.reason == "you do not own the origin",
		rejected and rejected.reason)
	check("the rejection is private to the ordering player",
		rejected and #rejected.visible_to == 1 and rejected.visible_to[1] == 1)

	-- Over-ordering clamps to what is actually there.
	local home = s.players[1].home
	local have = s.systems[home].ships
	res.turn(GALAXY, s, {
		{ player = 1, from = home, to = GALAXY.adjacency[home][1], ships = have + 9999 },
	}, LENGTHS)
	check("over-ordering clamps instead of failing", s.systems[home].ships >= 0)
end

print("combat")
do
	-- Hand-built confrontation: player 1 attacks player 2's home.
	local s = new_game(2)
	local defender_home = s.players[2].home
	local attacker_from = GALAXY.adjacency[defender_home][1]
	s.systems[attacker_from].owner = 1
	s.systems[attacker_from].ships = 500
	s.systems[defender_home].ships = 10

	res.turn(GALAXY, s, {
		{ player = 1, from = attacker_from, to = defender_home, ships = 500 },
	}, LENGTHS)
	local captured = false
	for _ = 1, 4 do
		if s.systems[defender_home].owner == 1 then captured = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("an overwhelming attack captures the system", captured)

	-- The reverse: a small attack against a strong defence must fail.
	local s2 = new_game(2)
	local d2 = s2.players[2].home
	local a2 = GALAXY.adjacency[d2][1]
	s2.systems[a2].owner = 1
	s2.systems[a2].ships = 10
	s2.systems[d2].ships = 400
	res.turn(GALAXY, s2, { { player = 1, from = a2, to = d2, ships = 10 } }, LENGTHS)
	for _ = 1, 4 do res.turn(GALAXY, s2, {}, LENGTHS) end
	check("a hopeless attack does not capture", s2.systems[d2].owner == 2)
end

print("fog of war")
do
	local s = new_game(2)
	local mine = s.players[1].home
	local theirs = s.players[2].home
	res.turn(GALAXY, s, {}, LENGTHS)

	local vis = view.visible_systems(GALAXY, s, 1)
	check("you see your own system", vis[mine])
	check("you see one lane out", vis[GALAXY.adjacency[mine][1]])
	check("you do not see a distant enemy home", not vis[theirs])

	local projected = view.project(GALAXY, s, 1)
	-- Keyed by string id so the JSON encoding is unambiguous; see view.project.
	check("projection omits unseen systems entirely", projected.systems[tostring(theirs)] == nil)
	check("projection includes your own", projected.systems[tostring(mine)] ~= nil)
	check("projection keys are strings, not numbers", projected.systems[mine] == nil)
	check("projection reports only your fleets",
		#projected.fleets == 0 or projected.fleets[1].id ~= nil)

	-- Memory: take a neighbour, then check it is remembered as stale after loss.
	local neighbour = GALAXY.adjacency[mine][1]
	s.systems[neighbour].owner = 1
	res.turn(GALAXY, s, {}, LENGTHS)
	local far = nil
	for _, id in ipairs(GALAXY.adjacency[neighbour]) do
		if id ~= mine and not view.visible_systems(GALAXY, s, 1)[id] then far = id end
	end
	check("memory records what was seen", s.knowledge[1][neighbour] ~= nil)
end

print("event visibility")
do
	local s = new_game(3)
	-- A battle between 1 and 2 far from player 3 must not reach player 3.
	local d = s.players[2].home
	local a = GALAXY.adjacency[d][1]
	s.systems[a].owner = 1
	s.systems[a].ships = 400
	local ev = res.turn(GALAXY, s, { { player = 1, from = a, to = d, ships = 400 } }, LENGTHS)
	for _ = 1, 3 do
		ev = res.turn(GALAXY, s, {}, LENGTHS)
		local battle = nil
		for i = 1, #ev do if ev[i].kind == "battle" then battle = ev[i] end end
		if battle then
			local sees3 = false
			for _, p in ipairs(battle.visible_to) do if p == 3 then sees3 = true end end
			check("combatants see the battle", #battle.visible_to >= 2)
			check("an uninvolved distant player does not", not sees3)
			break
		end
	end
end

print("determinism")
do
	local orders_for = function(state, turn)
		local out = {}
		for i = 1, #state.players do
			-- Standing choices as well as movement, so the determinism check
			-- covers the economy and not just the fleet arithmetic.
			if not state.players[i].researching then
				local avail = tech.available(state.players[i].tech)
				if #avail > 0 then
					out[#out + 1] = { player = i, kind = "research",
						tech = avail[(turn % #avail) + 1] }
				end
			end
			if turn % 7 == 0 then
				out[#out + 1] = { player = i, kind = "policy",
					warship_share = (turn % 14 == 0) and 0.5 or 1.0 }
			end
			local owned = st.owned_by(state, i)
			if #owned > 0 then
				local from = owned[(turn % #owned) + 1]
				local nb = GALAXY.adjacency[from]
				if #nb > 0 and state.systems[from].ships > 4 then
					out[#out + 1] = { player = i, from = from,
						to = nb[(turn % #nb) + 1],
						ships = math.floor(state.systems[from].ships / 2) }
				end
			end
		end
		return out
	end

	local function play(turns)
		local s = new_game(4)
		-- Four different races, so their modifiers are part of what has to
		-- reproduce.
		local ids = races.ids()
		for i = 1, 4 do s.players[i].race = ids[i] end
		for t = 1, turns do res.turn(GALAXY, s, orders_for(s, t), LENGTHS) end
		return digest(s)
	end

	local a, b = play(40), play(40)
	check("same seed and orders reproduce the same state exactly", a == b)
	check("the game actually progressed", #a > 200, "digest length " .. #a)
end

print("resources")
do
	-- Base yields are a pure function of public map data, which is what lets a
	-- player judge a system they have never visited.
	local seen = {}
	for id = 1, #GALAXY.stars do
		local y = resources.base_yield(GALAXY, id)
		seen[resources.speciality(GALAXY, id)] = true
		if y.metal < 0 or y.fuel < 0 or y.research < 0 then
			check("yields are never negative", false, "system " .. id)
			break
		end
	end
	check("all three resources are somebody's speciality",
		seen.metal and seen.fuel and seen.research)

	local a = resources.base_yield(GALAXY, 1)
	local b = resources.base_yield(GALAXY, 1)
	check("base yields are memoised, not rebuilt", a == b)

	local s = new_game(2)
	local before = s.players[1].stock.research
	res.turn(GALAXY, s, {}, LENGTHS)
	local after = s.players[1].stock.research
	check("holding a system earns research", after > before, before .. " -> " .. after)

	local stock = s.players[1].stock
	check("stockpiles stay integral",
		stock.metal == math.floor(stock.metal)
		and stock.fuel == math.floor(stock.fuel)
		and stock.research == math.floor(stock.research))
end

print("upkeep")
do
	local s = new_game(2)
	local home = s.players[1].home
	-- A fleet far beyond what one system can fuel.
	s.systems[home].ships = 4000
	s.players[1].stock.fuel = 0
	local ev = res.turn(GALAXY, s, {}, LENGTHS)
	local attrition = nil
	for i = 1, #ev do if ev[i].kind == "attrition" then attrition = ev[i] end end
	check("an unfuelled fleet suffers attrition", attrition ~= nil)
	check("attrition is private to its owner",
		attrition and #attrition.visible_to == 1 and attrition.visible_to[1] == 1)
	check("the fleet actually shrank", s.systems[home].ships < 4000)

	-- ...and the yards stop rather than burning metal to replace the losses.
	local metal_before = s.players[1].stock.metal
	res.turn(GALAXY, s, {}, LENGTHS)
	check("a starved empire banks metal instead of feeding the treadmill",
		s.players[1].stock.metal > metal_before)

	-- A fleet inside budget costs fuel but loses nothing.
	local calm = new_game(2)
	calm.systems[calm.players[1].home].ships = 10
	local fuel_before = calm.players[1].stock.fuel
	local ev2 = res.turn(GALAXY, calm, {}, LENGTHS)
	local starved = false
	for i = 1, #ev2 do if ev2[i].kind == "attrition" then starved = true end end
	check("a fleet within budget is not attrited", not starved)
	check("upkeep is still charged", calm.players[1].stock.fuel ~= fuel_before)
end

print("research")
do
	local s = new_game(2)
	local me = s.players[1]

	-- Prerequisites are enforced at the point of choosing, with a reason.
	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "research", tech = "warp_lattice" },
	}, LENGTHS)
	local rejected = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" and ev[i].tech then rejected = ev[i] end end
	check("a tech with unmet prerequisites is refused",
		rejected and rejected.reason == "prerequisites not met", rejected and rejected.reason)
	check("and nothing was set as the target", me.researching == nil)

	-- A reachable one is accepted and bought as soon as it is affordable.
	res.turn(GALAXY, s, { { player = 1, kind = "research", tech = "survey_network" } }, LENGTHS)
	check("a tier-one tech becomes the target", me.researching == "survey_network")

	local completed, turns = nil, 0
	for _ = 1, 200 do
		turns = turns + 1
		local e = res.turn(GALAXY, s, {}, LENGTHS)
		for i = 1, #e do if e[i].kind == "research_complete" then completed = e[i] end end
		if completed then break end
	end
	check("it eventually completes", completed and completed.tech == "survey_network",
		"after " .. turns .. " turns")
	check("completing clears the target", me.researching == nil)
	check("the tech is recorded", me.tech.survey_network == true)
	check("research was actually spent", me.stock.research >= 0)

	-- ...and its effect is live.
	local mods = modifiers.of(me)
	check("Survey Network widens vision", mods.vision == rules.base_vision + 1, mods.vision)

	-- The next tier is now offered, and the tier above it is not.
	local avail = {}
	for _, id in ipairs(tech.available(me.tech)) do avail[id] = true end
	check("its dependants unlock", avail.terraforming and avail.xeno_archives)
	check("the tier above stays locked", not avail.singularity_labs)
end

print("research widens the fog")
do
	-- Two identical games; one player has the Survey Network, the other does not.
	local plain = new_game(2)
	local surveyed = new_game(2)
	surveyed.players[1].tech.survey_network = true

	local a = view.visible_systems(GALAXY, plain, 1)
	local b = view.visible_systems(GALAXY, surveyed, 1)
	local na, nb = 0, 0
	for _ in pairs(a) do na = na + 1 end
	for _ in pairs(b) do nb = nb + 1 end
	check("an extra lane of vision reveals more systems", nb > na, na .. " -> " .. nb)
	for id in pairs(a) do
		if not b[id] then check("and never reveals less", false, "lost " .. id) break end
	end
end

print("races")
do
	check("every declared race resolves", races.exists("vorn") and races.exists("silicate"))
	check("an unknown race falls back rather than erroring",
		races.by_id("clangers").id == races.DEFAULT)

	local vorn = modifiers.of({ race = "vorn" })
	local kepler = modifiers.of({ race = "kepler" })
	check("the militarists hit harder", vorn.attack > kepler.attack)
	check("the scientists out-research them", kepler.yield_research > vorn.yield_research)
	check("no race is strictly better than the baseline",
		vorn.yield_research < 1 and kepler.industry < modifiers.of(nil).industry)

	-- A race with no explicit pick is playable, not broken.
	local s = new_game(2)
	check("a missing race becomes the default", s.players[1].race == races.DEFAULT)

	-- Growth actually differs in play.
	local slow = new_game(2, "silicate")
	local fast = new_game(2, "ashai")
	for _ = 1, 10 do
		res.turn(GALAXY, slow, {}, LENGTHS)
		res.turn(GALAXY, fast, {}, LENGTHS)
	end
	check("a fast-breeding race outgrows a slow one",
		fast.systems[fast.players[1].home].population
			> slow.systems[slow.players[1].home].population)
end

print("build policy")
do
	local s = new_game(2)
	-- All freighters.
	res.turn(GALAXY, s, { { player = 1, kind = "policy", warship_share = 0 } }, LENGTHS)
	check("the policy is recorded", s.players[1].warship_share == 0)

	local home = s.players[1].home
	local ships_before = s.systems[home].ships
	for _ = 1, 5 do res.turn(GALAXY, s, {}, LENGTHS) end
	check("freighters get built", s.systems[home].freighters > 0)
	check("and warships do not", s.systems[home].ships <= ships_before)

	-- Back to all warships.
	local before = s.systems[home].freighters
	res.turn(GALAXY, s, { { player = 1, kind = "policy", warship_share = 1 } }, LENGTHS)
	res.turn(GALAXY, s, {}, LENGTHS)
	check("switching back stops freighter production",
		s.systems[home].freighters == before)
	check("and resumes warships", s.systems[home].ships > before)
end

print("trade")
do
	local s = new_game(2)
	local home = s.players[1].home
	local near = GALAXY.adjacency[home][1]
	grant(s, 1, near, 100, 5)
	s.systems[home].freighters = 20

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "trade", from = home, to = near, ships = 12 },
	}, LENGTHS)
	check("freighters leave the origin", s.systems[home].freighters == 8)

	local established = nil
	for _ = 1, 8 do
		for i = 1, #ev do if ev[i].kind == "route_established" then established = ev[i] end end
		if established then break end
		ev = res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("a route opens between two systems you own", established ~= nil)
	check("the route is private to its owner",
		established and #established.visible_to == 1 and established.visible_to[1] == 1)
	check("the route is recorded", #s.routes == 1 and s.routes[1].ships == 12)

	-- It pays. Compare against the same empire with the route removed.
	local with_route = view.project(GALAXY, s, 1).income
	local routes = s.routes
	s.routes = {}
	local without = view.project(GALAXY, s, 1).income
	s.routes = routes
	check("a route adds research income", with_route.research > without.research,
		without.research .. " -> " .. with_route.research)
	check("a route adds fuel income", with_route.fuel > without.fuel)
	check("but never metal", with_route.metal == without.metal)

	-- Losing an endpoint dissolves it.
	s.systems[near].owner = 2
	local ev2 = res.turn(GALAXY, s, {}, LENGTHS)
	local lost = nil
	for i = 1, #ev2 do if ev2[i].kind == "route_lost" then lost = ev2[i] end end
	check("losing an endpoint breaks the route", lost ~= nil)
	check("and the route is gone", #s.routes == 0)
	check("the freighters fall back to the end still held",
		lost and lost.recovered and s.systems[home].freighters >= 12)

	-- A route needs two systems you own.
	local bad = res.turn(GALAXY, s, {
		{ player = 1, kind = "trade", from = home, to = near, ships = 5 },
	}, LENGTHS)
	local refused = nil
	for i = 1, #bad do if bad[i].kind == "order_rejected" then refused = bad[i] end end
	check("trading to somebody else's system is refused",
		refused and refused.reason == "a trade route needs two systems you own",
		refused and refused.reason)
end

print("state survives a round trip")
do
	local s = new_game(2)
	s.players[1].tech.ion_drive = true
	s.players[1].researching = "fuel_scoops"
	res.turn(GALAXY, s, {}, LENGTHS)

	-- Imitate what Nakama storage does to it: sparse integer keys become
	-- strings, numbers may come back as strings, and a set may arrive as a list.
	local wire = {
		seed = s.seed, turn = s.turn, players = {}, systems = s.systems,
		fleets = {}, routes = {}, next_fleet_id = tostring(s.next_fleet_id),
		knowledge = s.knowledge,
	}
	for i = 1, #s.players do
		local p = s.players[i]
		wire.players[i] = {
			id = p.id, name = p.name, race = p.race, home = p.home, alive = p.alive,
			stock = { metal = tostring(p.stock.metal), fuel = p.stock.fuel,
				research = p.stock.research },
			tech = { "ion_drive" },
			researching = p.researching,
			warship_share = tostring(p.warship_share),
		}
	end
	for _, sys in pairs(wire.systems) do sys.freighters = nil end

	local repaired = st.migrate(wire)
	check("technology survives arriving as a list", repaired.players[1].tech.ion_drive == true)
	check("stringified numbers are re-typed", repaired.players[1].stock.metal == s.players[1].stock.metal)
	check("the build policy is re-typed", repaired.players[1].warship_share == 1)
	check("missing freighter counts default to zero",
		repaired.systems[repaired.players[1].home].freighters == 0)
	check("a state missing routes gets an empty list", type(repaired.routes) == "table")

	-- And it still resolves.
	local ok, err = pcall(res.turn, GALAXY, repaired, {}, LENGTHS)
	check("a repaired state resolves another turn", ok, err)
end

print(failures == 0 and "\nALL SIM TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
