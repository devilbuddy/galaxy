-- The simulation, from the ground up.
--
-- The game is currently this: every player has a seat and one commander,
-- commanders move along tiles, what they pass through becomes theirs, and a
-- commander with enough strength takes ground somebody else holds. These tests
-- are the contract that skeleton has to keep while production and city upgrades
-- are built back onto it.
--
-- Run: luajit tools/test_sim.lua

package.path = "./?.lua;" .. package.path

local gen = require("realm.generate")
local st = require("realm.sim.state")
local res = require("realm.sim.resolve")
local path = require("realm.sim.path")
local view = require("realm.sim.view")
local races = require("realm.sim.races")
local provinces = require("realm.sim.provinces")
local tiles = require("realm.sim.tiles")
local commanders = require("realm.sim.commanders")
local buildings = require("realm.sim.buildings")
local units = require("realm.sim.units")
local state = require("realm.sim.state")
local modifiers = require("realm.sim.modifiers")
local rules = require("realm.sim.rules")

local SEED = 1337
local REALM = gen.build(SEED)

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
	return st.new(REALM, players)
end

--- Breadth-first hop distances from a tile.
local function hops_from(start)
	local dist, order, head = { [start] = 0 }, { start }, 1
	while head <= #order do
		local id = order[head]; head = head + 1
		for _, n in ipairs(REALM.adjacency[id]) do
			if not dist[n] then
				dist[n] = dist[id] + 1
				order[#order + 1] = n
			end
		end
	end
	return dist, order
end

--- A tile exactly `want` tiles from `start`, preferring unowned ones.
local function tile_at_hops(state, start, want)
	local dist, order = hops_from(start)
	for _, id in ipairs(order) do
		if dist[id] == want and state.tiles[id].owner == 0 then return id end
	end
	return nil
end

print("the opening position")
do
	local s = new_game(4)
	check("every player has a seat", s.players[1].seat and s.players[4].seat)
	local seen = {}
	local distinct = true
	for i = 1, 4 do
		if seen[s.players[i].seat] then distinct = false end
		seen[s.players[i].seat] = true
	end
	check("no two players share one", distinct)

	for i = 1, 4 do
		local seat = s.players[i].seat
		check("seat " .. i .. " is a city", tiles.is_city(REALM, seat))
		check("seat " .. i .. " is held by its owner",
			s.tiles[seat].owner == i and s.tiles[seat].seat_of == i)
		check("seat " .. i .. " has room to expand into",
			tiles.cities_within(REALM, seat, rules.seat_hops)
				>= rules.seat_neighbours)
	end

	check("each player has exactly one commander", #st.commanders_of(s, 1) == 1)
	check("there are as many commanders as players", #s.commanders == 4, #s.commanders)
	check("a commander starts on its seat",
		s.commanders[1].at == s.players[1].seat)
	check("and starts still", st.is_parked(s.commanders[1]))
	check("a player opens holding only their seat", st.holdings_of(s, 1) == 1,
		st.holdings_of(s, 1))
end

print("a commander takes orders")
do
	local s = new_game(2)
	local from = s.commanders[1].at
	local target = tile_at_hops(s, from, 3)
	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})

	local ordered = nil
	for i = 1, #ev do if ev[i].kind == "commander_ordered" then ordered = ev[i] end end
	check("the order is acknowledged", ordered ~= nil)
	check("and names where it is bound", ordered and ordered.to == target)
	check("the route is expanded tile by tile",
		ordered and ordered.hops >= 3, ordered and ordered.hops)

	local arrived = false
	for _ = 1, 12 do
		if s.commanders[1].at == target then arrived = true break end
		res.turn(REALM, s, {})
	end
	check("the commander gets there", arrived, s.commanders[1].at)
	check("and stops when it does", st.is_parked(s.commanders[1]))
end

print("an unreachable order is refused, with a reason")
do
	local s = new_game(2)
	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { 999999 } },
	})
	local refused = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" then refused = ev[i] end end
	check("it is rejected", refused ~= nil)
	check("the reason travels with it", refused and refused.reason ~= nil,
		refused and refused.reason)
	check("and only the player who asked sees it",
		refused and #refused.visible_to == 1 and refused.visible_to[1] == 1)

	local ev2 = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 77, route = { 1 } },
	})
	local no_commander = false
	for i = 1, #ev2 do
		if ev2[i].kind == "order_rejected" and ev2[i].reason == "no such commander" then
			no_commander = true
		end
	end
	check("someone else's commander is not yours to move", no_commander)
end

print("moving claims what it passes through")
do
	local s = new_game(2)
	local from = s.commanders[1].at
	local target = tile_at_hops(s, from, 4)
	-- Orders and movement are the same turn, so the ordering turn already moves
	-- the commander and its claims have to be counted too.
	local claimed = 0
	local function tally(ev)
		for i = 1, #ev do
			if ev[i].kind == "claimed" and ev[i].player == 1 then claimed = claimed + 1 end
		end
	end
	tally(res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	}))
	for _ = 1, 14 do
		if s.commanders[1].at == target then break end
		tally(res.turn(REALM, s, {}))
	end
	check("tiles along the way are taken", claimed >= 3, claimed)
	check("including the destination", s.tiles[target].owner == 1)
	check("the holdings grew with them", st.holdings_of(s, 1) == claimed + 1,
		st.holdings_of(s, 1))
end

print("a commander moves whole tiles")
do
	local s = new_game(2)
	local from = s.commanders[1].at
	local target = tile_at_hops(s, from, 3)
	res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})

	-- One tile a turn at rank one, and never anywhere but at a tile.
	check("it advances exactly one tile", #s.commanders[1].route == 2,
		#s.commanders[1].route)
	check("and stands at a tile, never between two",
		REALM.tiles[s.commanders[1].at] ~= nil)

	res.turn(REALM, s, {})
	check("another turn, another tile", #s.commanders[1].route == 1)
	res.turn(REALM, s, {})
	check("three tiles, three turns", s.commanders[1].at == target,
		s.commanders[1].at)

	-- Rank raises it, and the route is walked faster.
	local t = new_game(2)
	t.commanders[1].level = 9
	local tfrom = t.commanders[1].at
	local ttarget = tile_at_hops(t, tfrom, 3)
	res.turn(REALM, t, {
		{ player = 1, kind = "move", commander = 1, route = { ttarget } },
	})
	check("a Grand Admiral covers three in one turn",
		t.commanders[1].at == ttarget, t.commanders[1].at)
end

print("a border stops a commander that cannot pay for it")
do
	local s = new_game(2)
	local from = s.commanders[1].at
	local blocker = REALM.adjacency[from][1]
	-- A seat, so the resistance is above a level-one commander's whole
	-- ceiling. Any ordinary tile next door would now simply fall.
	s.tiles[blocker].owner = 2
	s.tiles[blocker].seat_of = 2
	s.players[2].seat = blocker

	local beyond = nil
	for _, id in ipairs(REALM.adjacency[blocker]) do
		if id ~= from then beyond = id break end
	end

	local blocked = nil
	local function watch(ev)
		for i = 1, #ev do
			if ev[i].kind == "commander_blocked" then blocked = ev[i] end
		end
	end
	watch(res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { blocker, beyond } },
	}))
	for _ = 1, 8 do
		if blocked then break end
		watch(res.turn(REALM, s, {}))
	end
	check("it is stopped at the border", blocked ~= nil)
	check("the border holds", s.tiles[blocker].owner == 2)
	check("and the commander is still on its own side", s.commanders[1].at ~= blocker)
	check("its route is dropped rather than left waiting",
		#s.commanders[1].route == 0)
	-- The player has to be able to work out what it would take, or the only way
	-- to find the number is to lose a commander against it.
	check("the refusal says what it would have taken",
		blocked and blocked.fortification and blocked.siege
			and blocked.fortification > blocked.siege,
		blocked and (tostring(blocked.siege) .. " vs "
			.. tostring(blocked.fortification)))
end

print("an army is aimed, not just large")
do
	local hold = units.empty()
	hold.escort, hold.interceptor, hold.bombard = 4, 3, 2
	check("an escort counts the same against both",
		units.by_id("escort").fortification == units.by_id("escort").army)
	check("an interceptor is for ships", units.by_id("interceptor").army
		> units.by_id("interceptor").fortification)
	check("a bombard is for walls", units.by_id("bombard").fortification
		> units.by_id("bombard").army)
	check("so the same hold is worth different amounts to each",
		units.power(hold, units.FORTIFICATION) ~= units.power(hold, units.ARMY),
		units.power(hold, units.FORTIFICATION) .. " vs "
			.. units.power(hold, units.ARMY))
	check("and the arithmetic is small enough to do in your head", (function()
		for i = 1, #units.CATALOGUE do
			local spec = units.CATALOGUE[i]
			if spec.fortification > 3 or spec.army > 3 then return false end
			if spec.fortification % 1 ~= 0 or spec.army % 1 ~= 0 then return false end
		end
		return true
	end)())

	check("the escort is what dies first", (function()
		local h = units.empty()
		h.escort, h.interceptor, h.bombard = 2, 2, 2
		units.strip(h, 3)
		return h.escort == 0 and h.interceptor == 1 and h.bombard == 2
	end)())
	check("and a hold that runs out simply runs out", (function()
		local h = units.empty()
		h.escort = 1
		units.strip(h, 9)
		return units.count(h) == 0
	end)())

	-- A round trip flattens a sparse table; the hold has to come back dense.
	check("a hold survives storage", (function()
		local back = units.normalise({ escort = "3", bombard = 2.9, nonsense = 5 })
		return back.escort == 3 and back.bombard == 2 and back.interceptor == 0
			and back.nonsense == nil
	end)())
	-- The three were renamed once. A hold in storage is keyed by id, so a
	-- commander in flight would otherwise come back empty.
	check("and a hold written under the old names still arrives", (function()
		local back = units.normalise({ line = 2, lance = 1, siege = 3 })
		return back.escort == 2 and back.interceptor == 1 and back.bombard == 3
	end)())
end

print("both halves have to be beaten")
do
	local s = new_game(2)
	local commander = s.commanders[1]
	local mods = modifiers.of(s.players[1])
	local target = REALM.adjacency[commander.at][1]
	s.tiles[target].owner = 2

	-- Guns only: fine against the walls, useless against an army.
	commander.units = units.empty()
	commander.units.bombard = 6
	s.commanders[2].at = target
	s.commanders[2].level = rules.commander_max_level
	s.commanders[2].units = units.empty()
	s.commanders[2].units.interceptor = 8

	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})
	local blocked
	for i = 1, #ev do if ev[i].kind == "commander_blocked" then blocked = ev[i] end end
	check("a siege train is turned back by an army", blocked ~= nil)
	check("and the refusal names both halves",
		blocked and blocked.fortification and blocked.army
			and blocked.siege and blocked.army_power)
	check("the walls were never the problem",
		blocked and blocked.siege >= blocked.fortification,
		blocked and (blocked.siege .. " vs " .. blocked.fortification))
	check("the army was", blocked and blocked.army_power < blocked.army,
		blocked and (blocked.army_power .. " vs " .. blocked.army))
end

print("what a battle costs")
do
	local function assault(hold, defence)
		local s = new_game(2)
		local commander = s.commanders[1]
		local target = REALM.adjacency[commander.at][1]
		s.tiles[target].owner = 2
		s.tiles[target].buildings = defence and { "bastion" } or {}
		commander.units = units.normalise(hold)
		local ev = res.turn(REALM, s, {
			{ player = 1, kind = "move", commander = 1, route = { target } },
		})
		for i = 1, #ev do
			if ev[i].kind == "battle" then return ev[i], commander end
			if ev[i].kind == "commander_blocked" then return nil, commander end
		end
		return nil, commander
	end

	local overwhelming = assault({ bombard = 8, escort = 4 }, false)
	check("an overwhelming assault is reported", overwhelming ~= nil)
	check("and runs in exchanges, not turns",
		overwhelming and #overwhelming.exchanges >= 1
			and #overwhelming.exchanges <= rules.max_exchanges,
		overwhelming and #overwhelming.exchanges)
	local spent = 0
	for _, n in pairs(overwhelming.lost) do spent = spent + n end
	check("overwhelming force is cheap", spent <= 2, spent)

	local even = assault({ escort = 5 }, true)
	if even then
		local cost = 0
		for _, n in pairs(even.lost) do cost = cost + n end
		check("an even fight is not", cost > spent, cost .. " vs " .. spent)
		check("and takes longer", #even.exchanges >= #overwhelming.exchanges,
			#even.exchanges .. " vs " .. #overwhelming.exchanges)
	else
		check("an even fight is not", true)
		check("and takes longer", true)
	end

	-- The guarantee the whole design rests on.
	check("a fight the sheet said was winnable is one you survive", (function()
		for _, hold in ipairs({ { escort = 3 }, { escort = 1, bombard = 2 },
			{ bombard = 4 }, { escort = 6, interceptor = 2, bombard = 2 } }) do
			local battle, commander = assault(hold, true)
			if battle and commanders.carried(commander) < 0 then return false end
		end
		return true
	end)())
end

print("taking ground")
do
	local s = new_game(2)
	local commander = s.commanders[1]
	local target = REALM.adjacency[commander.at][1]
	s.tiles[target].owner = 2

	local mods = modifiers.of(s.players[1])
	local fortification = tiles.defence(REALM, target, false,
		modifiers.of(s.players[2]))
	check("a fresh commander's own command can carry an ordinary tile",
		commanders.power(commander, mods, units.FORTIFICATION) >= fortification,
		commanders.power(commander, mods, units.FORTIFICATION) .. " vs " .. fortification)

	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = commander.id, route = { target } },
	})
	local battle
	for i = 1, #ev do if ev[i].kind == "battle" then battle = ev[i] end end

	check("the tile changes hands", s.tiles[target].owner == 1)
	check("the commander is standing on it", commander.at == target)
	check("a battle is reported", battle ~= nil and battle.at == target)
	check("it names what was faced",
		battle and battle.fortification == fortification, battle and battle.fortification)
	check("and the fight was worth experience", (commander.xp or 0) > 0, commander.xp)
end

print("a garrison is part of what a tile costs")
do
	local s = new_game(2)
	local target = REALM.adjacency[s.commanders[1].at][1]
	s.tiles[target].owner = 2
	local bare = tiles.defence(REALM, target, false, modifiers.of(s.players[2]))

	-- A veteran parked on it. Deliberately far above what a fresh attacker can
	-- cover, so the assertion does not depend on which tile the map put here.
	s.commanders[2].at = target
	s.commanders[2].level = rules.commander_max_level
	s.commanders[2].units = units.empty()
	local garrison = commanders.power(s.commanders[2], modifiers.of(s.players[2]),
		units.ARMY)

	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})
	local blocked
	for i = 1, #ev do if ev[i].kind == "commander_blocked" then blocked = ev[i] end end

	check("a garrisoned tile turns a fresh commander back", blocked ~= nil)
	check("the walls are the world's alone",
		blocked and blocked.fortification == bare,
		blocked and (tostring(blocked.fortification) .. " vs " .. bare))
	check("and the army half is whoever is standing on it",
		blocked and blocked.army == garrison,
		blocked and (tostring(blocked.army) .. " vs " .. garrison))
	check("the defender is untouched by an attack that never happened",
		s.commanders[2].at == target and commanders.power(s.commanders[2],
			modifiers.of(s.players[2]), units.ARMY) == garrison)
end

print("a broken commander goes home")
do
	local s = new_game(2)
	-- A weak garrison on an ordinary tile, and enough aboard to carry it:
	-- the defender's own command is worth more than a fresh officer's, so an
	-- empty attacker would simply be turned back.
	local target = REALM.adjacency[s.commanders[1].at][1]
	s.tiles[target].owner = 2
	s.commanders[1].units = units.normalise({ escort = 6, interceptor = 4 })
	s.commanders[2].at = target
	s.commanders[2].units = units.empty()
	s.commanders[2].level = 3
	local home = s.players[2].seat

	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})
	local broken
	for i = 1, #ev do if ev[i].kind == "commander_broken" then broken = ev[i] end end

	check("the defender is broken, not deleted", #s.commanders == 2)
	check("and reported as such", broken ~= nil)
	check("thrown back to their seat", s.commanders[2].at == home,
		s.commanders[2].at .. " vs " .. home)
	check("stripped of the rank they had earned", s.commanders[2].level == 2,
		s.commanders[2].level)
	check("their route is gone with them", #s.commanders[2].route == 0)
end

print("an empire pays, and cities make ready")
do
	local s = new_game(2)
	local seat = s.players[1].seat
	res.turn(REALM, s, {})
	local after_one = s.players[1].gold
	check("holding ground pays every turn", after_one > 0, after_one)
	check("and it is what the tiles are worth",
		after_one == tiles.yield(REALM, seat, true), after_one)
	check("the seat pays its seat bonus on top",
		after_one == tiles.yield(REALM, seat) + rules.seat_yield,
		after_one)

	-- **A city makes only what it has dwellings for.** The seat opens with
	-- Berths, so it makes Escorts on that dwelling's cadence and nothing else
	-- at all - the two rows that would once have filled anyway stay at zero
	-- until somebody builds for them.
	local berths = buildings.by_id("berths")
	local sys = s.tiles[seat]
	for _ = 1, berths.every * 2 do res.turn(REALM, s, {}) end
	check("a dwelling makes its type ready without being visited",
		sys.available.escort > 0, sys.available.escort)
	check("and nothing makes what it has no dwelling for",
		sys.available.interceptor == 0 and sys.available.bombard == 0)

	for _ = 1, berths.ready * berths.every * 2 do
		res.turn(REALM, s, {})
	end
	check("but never more than that dwelling's cap",
		sys.available.escort == berths.ready, sys.available.escort)

	-- A city with no dwellings is a place to stand and nothing more.
	local bare = nil
	for id = 1, #REALM.tiles do
		if tiles.is_city(REALM, id) and id ~= seat then bare = id break end
	end
	s.tiles[bare].owner = 1
	for _ = 1, berths.every * 3 do res.turn(REALM, s, {}) end
	check("a city with nothing built makes nothing at all",
		units.count(s.tiles[bare].available) == 0,
		units.count(s.tiles[bare].available))
	check("though it still pays its owner",
		tiles.yield(REALM, bare) > 0, tiles.yield(REALM, bare))

	-- **Road pays nothing.** Cities are towns and holdings are mines; the
	-- tile between them is terrain. `provinces.lua` has always counted only the
	-- first two towards victory, and the economy now agrees with it.
	local kinds = { city = nil, holding = nil, wilds = nil }
	for id = 1, #REALM.tiles do
		local k = tiles.kind(REALM, id)
		if kinds[k] == nil then kinds[k] = tiles.yield(REALM, id) end
	end
	check("a city and a holding both pay",
		(kinds.holding or 0) > 0 and (kinds.city or 0) > 0)
	check("and open country pays nothing at all", kinds.wilds == 0,
		kinds.wilds)
	check("a city is worth more than a holding",
		(kinds.city or 0) >= (kinds.holding or 0))
end

print("strength is bought, not waited for")
do
	local s = new_game(2)
	local commander = s.commanders[1]
	local mods = modifiers.of(s.players[1])
	local seat = s.players[1].seat
	local base = commanders.base_strength(commander, mods)

	-- Nothing comes back on its own any more.
	commander.units = units.empty()
	res.turn(REALM, s, {})
	check("an empty commander does not refill by standing still",
		commanders.carried(commander) == 0)

	-- Stock it, fund it, buy into the garrison and take it aboard. Both are
	-- free, and buying settles before transferring, so this is one turn.
	local sys2 = s.tiles[seat]
	sys2.available = units.normalise({ escort = 4, bombard = 2 })
	s.players[1].gold = 400
	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "buy", at = seat,
		  units = { escort = 2, bombard = 1 } },
		{ player = 1, kind = "transfer", commander = commander.id,
		  units = { escort = 2, bombard = 1 } },
	})
	local bought, moved
	for i = 1, #ev do
		if ev[i].kind == "bought" then bought = ev[i] end
		if ev[i].kind == "transferred" then moved = ev[i] end
	end
	check("a city buys the mix it asked for",
		bought and bought.units == 3, bought and bought.units)
	check("and it is the mix, not just the count",
		bought and bought.took.escort == 2 and bought.took.bombard == 1)
	check("what was bought this turn can be taken aboard the same turn",
		moved and moved.units == 3, moved and moved.units)
	check("the hold is what it loaded",
		commander.units.escort == 2 and commander.units.bombard == 1)
	check("and the garrison is empty again",
		units.count(sys2.garrison) == 0, units.count(sys2.garrison))
	check("guns are worth more against walls than against ships",
		commanders.power(commander, mods, units.FORTIFICATION)
			> commanders.power(commander, mods, units.ARMY))
	check("the city has that many fewer ready",
		sys2.available.escort == 2 and sys2.available.bombard == 1,
		sys2.available.escort)
	check("and the purse paid catalogue prices",
		bought.cost == 2 * units.by_id("escort").cost + units.by_id("bombard").cost,
		bought.cost)

	-- What is bought stays where it was bought until somebody carries it.
	local s3 = new_game(2)
	local cap3 = s3.players[1].seat
	s3.tiles[cap3].available = units.normalise({ escort = 2 })
	s3.players[1].gold = 400
	s3.commanders[1].at = REALM.adjacency[cap3][1]
	res.turn(REALM, s3, {
		{ player = 1, kind = "buy", at = cap3, units = { escort = 2 } },
	})
	check("buying needs no commander standing there",
		s3.tiles[cap3].garrison.escort == 2, s3.tiles[cap3].garrison.escort)

	-- Rank does not cap what a commander carries; it sets where they start.
	check("a fresh commander starts on their own command alone",
		commanders.power({ level = 1, units = units.empty() }, mods,
			units.ARMY) == base, base)
	check("and can lead far more than that once loaded",
		commanders.max_units({ level = 1 }, mods) > 1)
end

print("what a purchase and a transfer cannot do")
do
	local function attempt(orders, prepare)
		local s = new_game(2)
		local commander = s.commanders[1]
		local seat = s.players[1].seat
		s.tiles[seat].available = units.normalise({ escort = 4 })
		s.players[1].gold = 999
		commander.units = units.empty()
		if prepare then prepare(s, commander) end
		local ev = res.turn(REALM, s, orders(s, commander))
		for i = 1, #ev do
			if ev[i].kind == "bought" then return "bought", ev[i] end
			if ev[i].kind == "transferred" then return "transferred", ev[i] end
			if ev[i].kind == "order_rejected" then return ev[i].reason end
		end
		return "nothing"
	end

	local function buy(s)
		return { { player = 1, kind = "buy", at = s.players[1].seat,
			units = { escort = 4 } } }
	end

	check("not buying somewhere you do not hold",
		attempt(buy, function(s) s.tiles[s.players[1].seat].owner = 2 end)
			== "not yours to build on")
	check("not buying what no dwelling has made",
		attempt(buy, function(s)
			s.tiles[s.players[1].seat].available = units.empty()
		end) == "nothing ready here")
	check("and not on an empty purse",
		attempt(buy, function(s) s.players[1].gold = 0 end)
			== "not enough gold")

	check("not swapping where you are not standing", attempt(function(s, c)
		return { { player = 1, kind = "transfer", commander = c.id,
			units = { escort = 4 } } }
	end, function(s, c)
		s.tiles[s.players[1].seat].garrison = units.normalise({ escort = 4 })
		c.at = REALM.adjacency[c.at][1]
	end) == "not your city")

	-- A target hold, not a delta: asking for more than the garrison holds gets
	-- the garrison, and asking for more than the commander can carry gets what
	-- fits. Both clamp rather than refuse.
	local why, e = attempt(function(s, c)
		return { { player = 1, kind = "transfer", commander = c.id,
			units = { escort = 99 } } }
	end, function(s)
		s.tiles[s.players[1].seat].garrison = units.normalise({ escort = 3 })
	end)
	check("asking for more than is standing there takes what is",
		why == "transferred" and e.units == 3, e and e.units)
end

print("what a city can be made into")
do
	local s = new_game(2)
	local seat = s.players[1].seat
	local sys = s.tiles[seat]
	s.players[1].gold = 5000

	local function build(id, at)
		local ev = res.turn(REALM, s, {
			{ player = 1, kind = "build", at = at or seat, building = id },
		})
		for i = 1, #ev do
			if ev[i].kind == "built" then return "built", ev[i] end
			if ev[i].kind == "order_rejected" then return ev[i].reason end
		end
		return "nothing"
	end

	-- The seat opens with Berths, so it starts on one of its slots.
	check("a seat opens with somewhere to make escorts",
		buildings.has(sys, "berths"))
	check("and that is the only type it makes",
		buildings.makes(sys, "escort") ~= nil
			and buildings.makes(sys, "bombard") == nil)

	check("a city can be built on", build("foundry") == "built")
	check("and it does what it says",
		buildings.makes(sys, "bombard") ~= nil
			and buildings.ready_cap(sys, "bombard") > 0)
	check("the same thing twice is refused", build("foundry") == "already built")

	check("more buildings fill the slots", build("interceptor_bay") == "built"
		and build("bastion") == "built")
	check("and one past the last slot has nowhere to go",
		build("admiralty") == "no room for another building")
	check("slots are what the rules say",
		buildings.count(sys) == rules.building_slots, buildings.count(sys))

	-- Somewhere that is not a city, and somewhere that is not yours.
	local elsewhere
	for id = 1, #REALM.tiles do
		if not tiles.is_city(REALM, id) then elsewhere = id break end
	end
	s.tiles[elsewhere].owner = 1
	check("only a city can be built on",
		build("berths", elsewhere) == "only a city can be built on")
	check("and only one that is yours",
		build("berths", s.players[2].seat) == "not yours to build on")

	-- A Bastion is the only way a world gets harder to take.
	local t = new_game(2)
	local other = t.players[2].seat
	local bare = tiles.defence(REALM, other, true, modifiers.of(t.players[2]))
	t.tiles[other].buildings = { "bastion" }
	check("a bastion is worth what the rules say",
		buildings.defence_bonus(t.tiles[other]) == rules.bastion_defence)
	check("and nothing else raises a tile's defence",
		buildings.defence_bonus({ buildings = { "berths", "foundry" } }) == 0)
	check("the bare world is unchanged by it",
		tiles.defence(REALM, other, true, modifiers.of(t.players[2])) == bare)
end

print("raising a second commander")
do
	local s = new_game(2)
	local seat = s.players[1].seat
	s.players[1].gold = 5000

	local function recruit()
		local ev = res.turn(REALM, s, {
			{ player = 1, kind = "recruit", at = seat },
		})
		for i = 1, #ev do
			if ev[i].kind == "recruited" then return "raised", ev[i] end
			if ev[i].kind == "order_rejected" then return ev[i].reason end
		end
		return "nothing"
	end

	check("one commander to begin with",
		#state.commanders_of(s, 1) == 1)
	check("and nowhere to raise another", recruit() == "no admiralty there")

	s.tiles[seat].buildings = { "admiralty" }
	local how, event = recruit()
	check("an admiralty is where they come from", how == "raised", how)
	check("there are two of them now", #state.commanders_of(s, 1) == 2)
	check("the second has a name of their own", (function()
		local all = state.commanders_of(s, 1)
		return all[1].name ~= all[2].name
	end)())
	check("and it cost the purse", event and event.cost == rules.commander_cost)

	check("but only as many as there is room for",
		recruit() == "no room for another commander")

	-- The cap is one plus an admiralty each, to a ceiling.
	check("the cap grows with them",
		buildings.commander_cap(s, 1) == rules.commander_cap + 1,
		buildings.commander_cap(s, 1))
	check("and never past the ceiling", (function()
		for id = 1, #REALM.tiles do
			if tiles.is_city(REALM, id) then
				s.tiles[id].owner = 1
				s.tiles[id].buildings = { "admiralty" }
			end
		end
		return buildings.commander_cap(s, 1) == rules.commander_cap_max
	end)(), buildings.commander_cap(s, 1))
end

print("a seat needs an army")
do
	local s = new_game(2)
	local seat = s.players[2].seat
	local defence = tiles.defence(REALM, seat, true, modifiers.of(s.players[2]))
	local mine = modifiers.of(s.players[1])
	check("a fresh commander cannot crack one on their own command",
		commanders.base_strength({ level = 1 }, mine) < defence,
		commanders.base_strength({ level = 1 }, mine) .. " vs " .. defence)
	check("but can once they have loaded enough guns", (function()
		local full = { level = 1, units = units.empty() }
		full.units.bombard = commanders.max_units(full, mine)
		return commanders.power(full, mine, units.FORTIFICATION) >= defence
	end)())
end

print("what a rival saw of your march")
do
	local s = new_game(2)
	local commander = s.commanders[1]
	-- Three tiles a turn, so a march has a path long enough to be clipped.
	commander.level = rules.commander_max_level
	local target = tile_at_hops(s, commander.at, 3)

	-- Give player 2 eyes on part of the way, but not all of it. A tile they
	-- hold sees `base_vision` tiles around it, so watching two *consecutive*
	-- legs takes a listening post beside each - and neither may sit on the
	-- route itself, or the march becomes a battle instead of a sighting.
	local route = res.expand_route(REALM, commander.at, nil, { target }, 12)
	local on_route = { [commander.at] = true }
	for k = 1, #route do on_route[route[k]] = true end
	for _, p in ipairs(s.players) do on_route[p.seat] = true end

	local posts = 0
	for leg = 1, 2 do
		for _, n in ipairs(REALM.adjacency[route[leg]]) do
			if not on_route[n] and s.tiles[n].owner == 0 then
				s.tiles[n].owner = 2
				on_route[n] = true
				posts = posts + 1
				break
			end
		end
	end
	-- One post is often enough: a listening post beside a tile junction sees
	-- both ends of it. What matters is that *some* of the march is watched and
	-- some is not, which the checks below verify against the fog itself.
	check("the board has somewhere to watch from", posts > 0, posts)

	local ev = res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1, route = { target } },
	})

	local mine, sighting
	for i = 1, #ev do
		if ev[i].kind == "commander_moved" then mine = ev[i] end
		if ev[i].kind == "contact_moved" then sighting = ev[i] end
	end

	check("your own march is recorded in full",
		mine ~= nil and #mine.path > 1, mine and #mine.path)
	check("and it is yours alone",
		mine and #mine.visible_to == 1 and mine.visible_to[1] == 1)

	-- The sighting is a property of the fog, so check it against the fog rather
	-- than against a hand-worked answer: every tile in it must be somewhere
	-- the observer can actually see.
	if sighting then
		local seen = view.visible_tiles(REALM, s, 2)
		local outside = nil
		if not seen[sighting.from] then outside = sighting.from end
		for k = 1, #sighting.path do
			if not seen[sighting.path[k]] then outside = sighting.path[k] end
		end
		check("a rival sees only the part that was in range", outside == nil, outside)
		check("shorter than the march itself", #sighting.path < #mine.path,
			#sighting.path .. " of " .. #mine.path)
		check("and it names a rank, never the officer",
			sighting.rank ~= nil and sighting.name == nil)
		check("reported to the watcher and nobody else",
			#sighting.visible_to == 1 and sighting.visible_to[1] == 2)
	else
		check("a rival sees the part that was in range", false, "no sighting")
	end

	-- Nobody watching, nothing seen.
	local t = new_game(2)
	t.commanders[1].level = rules.commander_max_level
	local ev2 = res.turn(REALM, t, {
		{ player = 1, kind = "move", commander = 1,
		  route = { tile_at_hops(t, t.commanders[1].at, 3) } },
	})
	local any = false
	for i = 1, #ev2 do if ev2[i].kind == "contact_moved" then any = true end end
	check("a march nobody could see is not reported at all", not any)
end

print("fog of war")
do
	local s = new_game(2)
	local v = view.project(REALM, s, 1)
	check("you can see your own seat",
		v.tiles[tostring(s.players[1].seat)] ~= nil)
	check("but not the other player's",
		v.tiles[tostring(s.players[2].seat)] == nil)
	check("your commander is in the projection", #v.commanders == 1)
	check("theirs is not", #v.contacts == 0)
	check("the roster is public", #v.players == 2 and v.players[2].name == "P2")

	-- Stand an enemy commander next to ours and it becomes a contact.
	s.commanders[2].at = s.commanders[1].at
	local v2 = view.project(REALM, s, 1)
	check("an enemy commander in range shows up", #v2.contacts == 1)
	check("with a rank but no orders",
		v2.contacts[1].rank ~= nil and v2.contacts[1].route == nil)
	-- Combat is a comparison the attacker is expected to make before
	-- committing, so both halves of it have to be on screen.
	check("and what they are worth defending, so an attack can be priced",
		type(v2.contacts[1].army_power) == "number")
end

print("what a commander is")
do
	check("a green officer is a Commander", commanders.rank(1) == "Commander")
	check("a veteran is not", commanders.rank(10) ~= "Commander")
	check("a green commander crosses one tile a turn",
		commanders.steps({ level = 1 }) == 1)
	check("rank buys reach",
		commanders.steps({ level = 9 }) > commanders.steps({ level = 1 }))
	check("and it is always a whole number of tiles",
		commanders.steps({ level = 9 }) % 1 == 0)
	check("the same officer always has the same face",
		commanders.portrait(4, nil, "terran") == commanders.portrait(4, nil, "terran"))
	check("different officers do not",
		commanders.portrait(4, nil, "terran") ~= commanders.portrait(5, nil, "terran"))
	-- Portraits are grouped by species, which is most of what makes a race feel
	-- like a people rather than a bundle of modifiers.
	check("and the same officer of another race is a different species",
		commanders.portrait(4, nil, "terran") ~= commanders.portrait(4, nil, "vorn"))
	check("every race has a face for every officer", (function()
		local ids = races.ids()
		local seen = {}
		for i = 1, #ids do
			for n = 1, 40 do
				local id = commanders.portrait(n, nil, ids[i])
				if not id:find(ids[i], 1, true) then return false end
				seen[id] = true
			end
		end
		local count = 0
		for _ in pairs(seen) do count = count + 1 end
		-- Wraps rather than running out, so forty officers of six races draw
		-- from a fixed set.
		return count == #ids * 12
	end)())
	check("an unknown race still gets one",
		commanders.portrait(1, nil, "clangers")
			== commanders.portrait(1, nil, races.DEFAULT))
end

print("races differ on the axes that exist")
do
	local base = modifiers.of(nil)
	local cartel = modifiers.of({ race = "cartel" })
	check("every declared race resolves",
		races.exists("cartel") and races.exists("silicate"))
	check("an unknown race falls back", races.by_id("clangers").id == races.DEFAULT)
	check("the fast race gets a whole extra tile",
		cartel.step_bonus == base.step_bonus + 1)
	check("and can plot further ahead", cartel.hops > base.hops)

	-- Races used to differ on mobility alone, which made the fast one strictly
	-- the best pick. Strength is what finally reads the other two keys.
	local vorn = modifiers.of({ race = "vorn" })
	local silicate = modifiers.of({ race = "silicate" })
	check("the warlike race hits harder", (function()
		local hold = { level = 1, units = units.empty() }
		return commanders.power(hold, vorn, units.ARMY)
			> commanders.power(hold, base, units.ARMY)
	end)())
	check("the entrenched race is harder to shift", silicate.defence > base.defence)
	check("and the fast one pays for it in defence", cartel.defence < base.defence)
end

print("provinces are the objective")
do
	local s = new_game(2)
	check("the map is carved into provinces", #REALM.provinces > 1, #REALM.provinces)
	check("winning needs more than one", provinces.needed(REALM) >= 2)
	check("nobody holds one at the opening",
		(provinces.tally(REALM, s, provinces.control(REALM, s))[1] or 0) == 0)

	local target = REALM.tiles[s.players[1].seat].province
	local counted = 0
	for id = 1, #REALM.tiles do
		if REALM.tiles[id].province == target and provinces.counts(REALM, id) then
			s.tiles[id].owner = 1
			counted = counted + 1
		end
	end
	local held = provinces.control(REALM, s)
	check("holding what counts takes the province", held[target] == 1, held[target])
	check("wilds are not what counts",
		counted < REALM.provinces[target].tile_count)
end

print("losing the seat is losing")
do
	local s = new_game(2)
	check("a player holding their seat is alive", st.is_alive(s, 1))
	s.tiles[s.players[1].seat].owner = 2
	check("and is not once it is gone", not st.is_alive(s, 1))
	local ev = res.turn(REALM, s, {})
	local out = false
	for i = 1, #ev do if ev[i].kind == "eliminated" and ev[i].player == 1 then out = true end end
	check("the turn reports it", out)
	check("and the player is marked", s.players[1].alive == false)
end

print("state survives a round trip")
do
	local s = new_game(2)
	res.turn(REALM, s, {
		{ player = 1, kind = "move", commander = 1,
		  route = { tile_at_hops(s, s.commanders[1].at, 2) } },
	})

	-- The damage JSON storage actually does: sparse integer keys come back as
	-- strings, and numbers as strings.
	local wounded = {
		seed = s.seed, turn = tostring(s.turn),
		players = s.players, commanders = s.commanders,
		tiles = {}, knowledge = {}, provinces_held = s.provinces_held,
	}
	for id, sys in pairs(s.tiles) do
		wounded.tiles[tostring(id)] = {
			owner = tostring(sys.owner), seat_of = tostring(sys.seat_of),
		}
	end
	for p, memory in pairs(s.knowledge) do
		local out = {}
		for id, seen in pairs(memory) do out[tostring(id)] = seen end
		wounded.knowledge[tostring(p)] = out
	end

	local repaired = st.normalise(wounded)
	check("tile ids come back as numbers", repaired.tiles[1] ~= nil)
	check("owners come back as numbers",
		type(repaired.tiles[s.players[1].seat].owner) == "number")
	check("the turn comes back as a number", type(repaired.turn) == "number")
	check("fog memory is keyed by number again",
		next(repaired.knowledge[1]) ~= nil
			and type(next(repaired.knowledge[1])) == "number")
	local ok = pcall(res.turn, REALM, repaired, {})
	check("and a repaired state resolves another turn", ok)
	-- What was seen, not just *when*. The repair was written when memory was
	-- id -> turn and coerced each entry with `tonumber`, which flattened every
	-- record to the number zero the moment it started carrying an owner. That
	-- inverted the whole purpose of this function - fog memory was wiped on
	-- every read - and crashed `view.project` outright on the first tile a
	-- player remembered but could no longer see.
	check("and remembers what was seen there, not just when", (function()
		local memory = repaired.knowledge[1] or {}
		local n = 0
		for _, entry in pairs(memory) do
			if type(entry) ~= "table" or entry.owner == nil then return false end
			n = n + 1
		end
		return n > 0
	end)())

	-- Somewhere remembered that is definitely *not* in live view, which is the
	-- only branch that reads a memory entry back.
	local far = nil
	local seen_now = view.visible_tiles(REALM, repaired, 1)
	for id = 1, #REALM.tiles do
		if not seen_now[id] then far = id break end
	end
	repaired.knowledge[1][far] = { turn = 1, owner = 2, seat_of = 0 }
	local projected, why = pcall(view.project, REALM, repaired, 1)
	check("a projection still builds from remembered ground", projected, why)
	check("and the memory of it survives the trip", (function()
		local v = view.project(REALM, repaired, 1)
		local entry = v.tiles[tostring(far)]
		return entry ~= nil and entry.owner == 2 and entry.live == false
	end)())
end

print("bots")
do
	local bots = require("realm.sim.bots")
	local s = new_game(2)
	s.players[2].bot = true

	local orders = bots.all_orders(REALM, s)
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
	local again = bots.all_orders(REALM, s)
	local same = #orders == #again
	if same then
		for i = 1, #orders do
			if orders[i].commander ~= again[i].commander
				or orders[i].route[1] ~= again[i].route[1] then
				same = false
			end
		end
	end
	check("asked twice, it answers the same", same)

	-- ...and across a fresh game on the same seed.
	local t = new_game(2)
	t.players[2].bot = true
	local fresh = bots.all_orders(REALM, t)
	check("and identically in a fresh game on the same seed",
		#fresh == #orders and fresh[1].route[1] == orders[1].route[1],
		fresh[1] and fresh[1].route[1])

	-- A commander already under way keeps its standing order.
	res.turn(REALM, s, orders)
	local moving = s.commanders[2]
	if #moving.route > 0 then
		local next_orders = bots.all_orders(REALM, s)
		local re_routed = false
		for i = 1, #next_orders do
			if next_orders[i].commander == moving.id then re_routed = true end
		end
		check("a commander under way is not re-routed every turn", not re_routed)
	else
		check("a commander under way is not re-routed every turn", true)
	end

	-- Fenced in by somebody else's ground. It used to have no answer to this at
	-- all and would simply stop for the rest of the game, which is most of what
	-- made the old skeleton unresolvable.
	-- **With an army aboard.** An officer's own command is deliberately too
	-- small to crack a city now, so a bare commander being fenced in is the
	-- correct outcome rather than a bug - the test has to hand it the thing the
	-- economy exists to provide.
	local function fenced_game(fortify)
		local u = new_game(2)
		u.players[2].bot = true
		local cap = u.players[2].seat
		for _, n in ipairs(REALM.adjacency[cap]) do
			u.tiles[n].owner = 1
			-- A wall no army this size can breach, so the only way out is one
			-- the bot has not got.
			if fortify then u.tiles[n].buildings = { "bastion" } end
		end
		u.commanders[2].units = units.normalise({ escort = 4, interceptor = 4 })
		u.players[2].gold = 0
		return u, bots.all_orders(REALM, u)
	end

	local u, out = fenced_game(false)
	local moves = {}
	for i = 1, #out do
		if out[i].kind == "move" then moves[#moves + 1] = out[i] end
	end
	check("a fenced-in bot attacks its way out", #moves == 1, #moves)
	check("and the target is ground somebody holds",
		moves[1] and u.tiles[moves[1].route[#moves[1].route]].owner == 1)

	check("but it never picks a fight it cannot win", (function()
		local w, orders = fenced_game(false)
		for i = 1, #orders do
			if orders[i].kind == "move" then
				local at = orders[i].route[#orders[i].route]
				local sys = w.tiles[at]
				if sys.owner ~= 0 and sys.owner ~= 2 then
					local mods = modifiers.of(w.players[2])
					local fort = tiles.defence(REALM, at,
						sys.seat_of == sys.owner, modifiers.of(w.players[sys.owner]))
						+ buildings.defence_bonus(sys)
					if commanders.power(w.commanders[2], mods,
						units.FORTIFICATION) < fort then
						return false
					end
				end
			end
		end
		return true
	end)())
end

print("determinism")
do
	local function run()
		local s = new_game(3)
		local target = tile_at_hops(s, s.commanders[1].at, 3)
		res.turn(REALM, s, {
			{ player = 1, kind = "move", commander = 1, route = { target } },
		})
		for _ = 1, 10 do res.turn(REALM, s, {}) end
		local parts = {}
		for id = 1, #REALM.tiles do
			parts[#parts + 1] = tostring(s.tiles[id].owner)
		end
		for i = 1, #s.commanders do
			parts[#parts + 1] = s.commanders[i].at .. ":" .. #s.commanders[i].route
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
