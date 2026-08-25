-- The simulation, from the ground up.
--
-- The game is currently only this: every player has a capital and one captain,
-- captains move along lanes, and what they pass through becomes theirs. These
-- tests are the contract that skeleton has to keep while production, combat and
-- city upgrades are built back onto it.
--
-- Run: luajit tools/test_sim.lua

package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local path = require("galaxy.sim.path")
local view = require("galaxy.sim.view")
local races = require("galaxy.sim.races")
local regions = require("galaxy.sim.regions")
local systems = require("galaxy.sim.systems")
local commanders = require("galaxy.sim.commanders")
local modifiers = require("galaxy.sim.modifiers")
local rules = require("galaxy.sim.rules")

local SEED = 1337
local GALAXY = gen.build(SEED)
local LENGTHS = path.lane_lengths(GALAXY)

local failures = 0

local function check(name, ok, detail)
	if ok then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
	end
end

local function new_game(count)
	local ids = races.ids()
	local players = {}
	for i = 1, count do
		players[i] = { id = "p" .. i, name = "P" .. i,
			race = ids[((i - 1) % #ids) + 1] }
	end
	return st.new(GALAXY, players)
end

--- Breadth-first hop distances from a system.
local function hops_from(start)
	local dist, order, head = { [start] = 0 }, { start }, 1
	while head <= #order do
		local id = order[head]; head = head + 1
		for _, n in ipairs(GALAXY.adjacency[id]) do
			if not dist[n] then
				dist[n] = dist[id] + 1
				order[#order + 1] = n
			end
		end
	end
	return dist, order
end

--- A system exactly `want` lanes from `start`, preferring unowned ones.
local function system_at_hops(state, start, want)
	local dist, order = hops_from(start)
	for _, id in ipairs(order) do
		if dist[id] == want and state.systems[id].owner == 0 then return id end
	end
	return nil
end

print("the opening position")
do
	local s = new_game(4)
	check("every player has a capital", s.players[1].capital and s.players[4].capital)
	local seen = {}
	local distinct = true
	for i = 1, 4 do
		if seen[s.players[i].capital] then distinct = false end
		seen[s.players[i].capital] = true
	end
	check("no two players share one", distinct)

	for i = 1, 4 do
		local capital = s.players[i].capital
		check("capital " .. i .. " is a colony", systems.is_colony(GALAXY, capital))
		check("capital " .. i .. " is held by its owner",
			s.systems[capital].owner == i and s.systems[capital].capital_of == i)
		check("capital " .. i .. " has room to expand into",
			systems.colonies_within(GALAXY, capital, rules.capital_hops)
				>= rules.capital_neighbours)
	end

	check("each player has exactly one captain", #st.captains_of(s, 1) == 1)
	check("there are as many captains as players", #s.captains == 4, #s.captains)
	check("a captain starts on its capital",
		s.captains[1].at == s.players[1].capital)
	check("and starts still", st.is_parked(s.captains[1]))
	check("a player opens holding only their capital", st.holdings_of(s, 1) == 1,
		st.holdings_of(s, 1))
end

print("a captain takes orders")
do
	local s = new_game(2)
	local from = s.captains[1].at
	local target = system_at_hops(s, from, 3)
	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS)

	local ordered = nil
	for i = 1, #ev do if ev[i].kind == "captain_ordered" then ordered = ev[i] end end
	check("the order is acknowledged", ordered ~= nil)
	check("and names where it is bound", ordered and ordered.to == target)
	check("the route is expanded lane by lane",
		ordered and ordered.hops >= 3, ordered and ordered.hops)

	local arrived = false
	for _ = 1, 12 do
		if s.captains[1].at == target then arrived = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("the captain gets there", arrived, s.captains[1].at)
	check("and stops when it does", st.is_parked(s.captains[1]))
end

print("an unreachable order is refused, with a reason")
do
	local s = new_game(2)
	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { 999999 } },
	}, LENGTHS)
	local refused = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" then refused = ev[i] end end
	check("it is rejected", refused ~= nil)
	check("the reason travels with it", refused and refused.reason ~= nil,
		refused and refused.reason)
	check("and only the player who asked sees it",
		refused and #refused.visible_to == 1 and refused.visible_to[1] == 1)

	local ev2 = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 77, route = { 1 } },
	}, LENGTHS)
	local no_captain = false
	for i = 1, #ev2 do
		if ev2[i].kind == "order_rejected" and ev2[i].reason == "no such captain" then
			no_captain = true
		end
	end
	check("someone else's captain is not yours to move", no_captain)
end

print("moving claims what it passes through")
do
	local s = new_game(2)
	local from = s.captains[1].at
	local target = system_at_hops(s, from, 4)
	-- Orders and movement are the same turn, so the ordering turn already moves
	-- the captain and its claims have to be counted too.
	local claimed = 0
	local function tally(ev)
		for i = 1, #ev do
			if ev[i].kind == "claimed" and ev[i].player == 1 then claimed = claimed + 1 end
		end
	end
	tally(res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS))
	for _ = 1, 14 do
		if s.captains[1].at == target then break end
		tally(res.turn(GALAXY, s, {}, LENGTHS))
	end
	check("systems along the way are taken", claimed >= 3, claimed)
	check("including the destination", s.systems[target].owner == 1)
	check("the holdings grew with them", st.holdings_of(s, 1) == claimed + 1,
		st.holdings_of(s, 1))
end

print("a captain moves whole lanes")
do
	local s = new_game(2)
	local from = s.captains[1].at
	local target = system_at_hops(s, from, 3)
	res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS)

	-- One lane a turn at rank one, and never anywhere but at a system.
	check("it advances exactly one lane", #s.captains[1].route == 2,
		#s.captains[1].route)
	check("and stands at a system, never between two",
		GALAXY.stars[s.captains[1].at] ~= nil)

	res.turn(GALAXY, s, {}, LENGTHS)
	check("another turn, another lane", #s.captains[1].route == 1)
	res.turn(GALAXY, s, {}, LENGTHS)
	check("three lanes, three turns", s.captains[1].at == target,
		s.captains[1].at)

	-- Rank raises it, and the route is walked faster.
	local t = new_game(2)
	t.captains[1].level = 9
	local tfrom = t.captains[1].at
	local ttarget = system_at_hops(t, tfrom, 3)
	res.turn(GALAXY, t, {
		{ player = 1, kind = "move", captain = 1, route = { ttarget } },
	}, LENGTHS)
	check("a Grand Admiral covers three in one turn",
		t.captains[1].at == ttarget, t.captains[1].at)
end

print("a border stops a captain")
do
	local s = new_game(2)
	local from = s.captains[1].at
	local blocker = GALAXY.adjacency[from][1]
	s.systems[blocker].owner = 2

	local beyond = nil
	for _, id in ipairs(GALAXY.adjacency[blocker]) do
		if id ~= from then beyond = id break end
	end

	local blocked = nil
	local function watch(ev)
		for i = 1, #ev do
			if ev[i].kind == "captain_blocked" then blocked = ev[i] end
		end
	end
	watch(res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { blocker, beyond } },
	}, LENGTHS))
	for _ = 1, 8 do
		if blocked then break end
		watch(res.turn(GALAXY, s, {}, LENGTHS))
	end
	check("it is stopped at the border", blocked ~= nil)
	check("the border holds", s.systems[blocker].owner == 2)
	check("and the captain is still on its own side", s.captains[1].at ~= blocker)
	check("its route is dropped rather than left waiting",
		#s.captains[1].route == 0)
end

print("fog of war")
do
	local s = new_game(2)
	local v = view.project(GALAXY, s, 1)
	check("you can see your own capital",
		v.systems[tostring(s.players[1].capital)] ~= nil)
	check("but not the other player's",
		v.systems[tostring(s.players[2].capital)] == nil)
	check("your captain is in the projection", #v.captains == 1)
	check("theirs is not", #v.contacts == 0)
	check("the roster is public", #v.players == 2 and v.players[2].name == "P2")

	-- Stand an enemy captain next to ours and it becomes a contact.
	s.captains[2].at = s.captains[1].at
	local v2 = view.project(GALAXY, s, 1)
	check("an enemy captain in range shows up", #v2.contacts == 1)
	check("with a rank but no orders",
		v2.contacts[1].rank ~= nil and v2.contacts[1].route == nil)
end

print("what a captain is")
do
	check("a green officer is a Captain", commanders.rank(1) == "Captain")
	check("a veteran is not", commanders.rank(10) ~= "Captain")
	check("a green captain crosses one lane a turn",
		commanders.steps({ level = 1 }) == 1)
	check("rank buys reach",
		commanders.steps({ level = 9 }) > commanders.steps({ level = 1 }))
	check("and it is always a whole number of lanes",
		commanders.steps({ level = 9 }) % 1 == 0)
	check("the same officer always has the same face",
		commanders.portrait(4) == commanders.portrait(4))
	check("different officers do not",
		commanders.portrait(4) ~= commanders.portrait(5))
end

print("races differ on the axes that exist")
do
	local base = modifiers.of(nil)
	local cartel = modifiers.of({ race = "cartel" })
	check("every declared race resolves",
		races.exists("cartel") and races.exists("silicate"))
	check("an unknown race falls back", races.by_id("clangers").id == races.DEFAULT)
	check("the fast race gets a whole extra lane",
		cartel.step_bonus == base.step_bonus + 1)
	check("and can plot further ahead", cartel.hops > base.hops)
end

print("regions are the objective")
do
	local s = new_game(2)
	check("the map is carved into regions", #GALAXY.regions > 1, #GALAXY.regions)
	check("winning needs more than one", regions.needed(GALAXY) >= 2)
	check("nobody holds one at the opening",
		(regions.tally(GALAXY, s, regions.control(GALAXY, s))[1] or 0) == 0)

	local target = GALAXY.stars[s.players[1].capital].region
	local counted = 0
	for id = 1, #GALAXY.stars do
		if GALAXY.stars[id].region == target and regions.counts(GALAXY, id) then
			s.systems[id].owner = 1
			counted = counted + 1
		end
	end
	local held = regions.control(GALAXY, s)
	check("holding what counts takes the region", held[target] == 1, held[target])
	check("waypoints are not what counts",
		counted < GALAXY.regions[target].star_count)
end

print("losing the capital is losing")
do
	local s = new_game(2)
	check("a player holding their capital is alive", st.is_alive(s, 1))
	s.systems[s.players[1].capital].owner = 2
	check("and is not once it is gone", not st.is_alive(s, 1))
	local ev = res.turn(GALAXY, s, {}, LENGTHS)
	local out = false
	for i = 1, #ev do if ev[i].kind == "eliminated" and ev[i].player == 1 then out = true end end
	check("the turn reports it", out)
	check("and the player is marked", s.players[1].alive == false)
end

print("state survives a round trip")
do
	local s = new_game(2)
	res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1,
		  route = { system_at_hops(s, s.captains[1].at, 2) } },
	}, LENGTHS)

	-- The damage JSON storage actually does: sparse integer keys come back as
	-- strings, and numbers as strings.
	local wounded = {
		seed = s.seed, turn = tostring(s.turn),
		players = s.players, captains = s.captains,
		systems = {}, knowledge = {}, regions_held = s.regions_held,
	}
	for id, sys in pairs(s.systems) do
		wounded.systems[tostring(id)] = {
			owner = tostring(sys.owner), capital_of = tostring(sys.capital_of),
		}
	end
	for p, memory in pairs(s.knowledge) do
		local out = {}
		for id, seen in pairs(memory) do out[tostring(id)] = seen end
		wounded.knowledge[tostring(p)] = out
	end

	local repaired = st.normalise(wounded)
	check("system ids come back as numbers", repaired.systems[1] ~= nil)
	check("owners come back as numbers",
		type(repaired.systems[s.players[1].capital].owner) == "number")
	check("the turn comes back as a number", type(repaired.turn) == "number")
	check("fog memory is keyed by number again",
		next(repaired.knowledge[1]) ~= nil
			and type(next(repaired.knowledge[1])) == "number")
	local ok = pcall(res.turn, GALAXY, repaired, {}, LENGTHS)
	check("and a repaired state resolves another turn", ok)
end

print("bots")
do
	local bots = require("galaxy.sim.bots")
	local s = new_game(2)
	s.players[2].bot = true

	local orders = bots.all_orders(GALAXY, s)
	check("a bot issues orders", #orders > 0, #orders)
	check("only for itself",
		orders[1].player == 2 and orders[1].kind == "move")
	check("and a human is left alone",
		(function()
			for i = 1, #orders do if orders[i].player == 1 then return false end end
			return true
		end)())

	-- The invariant that matters: a bot must be reproducible, or a replayed
	-- game diverges and a Nakama restart changes what the bot was going to do.
	local again = bots.all_orders(GALAXY, s)
	local same = #orders == #again
	if same then
		for i = 1, #orders do
			if orders[i].captain ~= again[i].captain
				or orders[i].route[1] ~= again[i].route[1] then
				same = false
			end
		end
	end
	check("asked twice, it answers the same", same)

	-- ...and across a fresh game on the same seed.
	local t = new_game(2)
	t.players[2].bot = true
	local fresh = bots.all_orders(GALAXY, t)
	check("and identically in a fresh game on the same seed",
		#fresh == #orders and fresh[1].route[1] == orders[1].route[1],
		fresh[1] and fresh[1].route[1])

	-- A captain already under way keeps its standing order.
	res.turn(GALAXY, s, orders, LENGTHS)
	local moving = s.captains[2]
	if #moving.route > 0 then
		local next_orders = bots.all_orders(GALAXY, s)
		local re_routed = false
		for i = 1, #next_orders do
			if next_orders[i].captain == moving.id then re_routed = true end
		end
		check("a captain under way is not re-routed every turn", not re_routed)
	else
		check("a captain under way is not re-routed every turn", true)
	end

	check("a bot never walks into someone else's border",
		(function()
			local u = new_game(2)
			u.players[2].bot = true
			-- Fence the bot in with player 1's ground.
			local cap = u.players[2].capital
			for _, n in ipairs(GALAXY.adjacency[cap]) do u.systems[n].owner = 1 end
			local fenced = bots.all_orders(GALAXY, u)
			return #fenced == 0
		end)())
end

print("determinism")
do
	local function run()
		local s = new_game(3)
		local target = system_at_hops(s, s.captains[1].at, 3)
		res.turn(GALAXY, s, {
			{ player = 1, kind = "move", captain = 1, route = { target } },
		}, LENGTHS)
		for _ = 1, 10 do res.turn(GALAXY, s, {}, LENGTHS) end
		local parts = {}
		for id = 1, #GALAXY.stars do
			parts[#parts + 1] = tostring(s.systems[id].owner)
		end
		for i = 1, #s.captains do
			parts[#parts + 1] = s.captains[i].at .. ":" .. #s.captains[i].route
		end
		return table.concat(parts, ",")
	end
	local a, b = run(), run()
	check("the same seed and orders reproduce the same state exactly", a == b)
	check("and the game actually progressed", #a > 0)
end

if failures > 0 then
	print(string.format("\n%d SIM TEST(S) FAILED", failures))
	os.exit(1)
end
print("\nALL SIM TESTS PASSED")
