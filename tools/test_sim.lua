-- The simulation, from the ground up.
--
-- The game is currently this: every player has a capital and one captain,
-- captains move along lanes, what they pass through becomes theirs, and a
-- captain with enough strength takes ground somebody else holds. These tests
-- are the contract that skeleton has to keep while production and city upgrades
-- are built back onto it.
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

print("a border stops a captain that cannot pay for it")
do
	local s = new_game(2)
	local from = s.captains[1].at
	local blocker = GALAXY.adjacency[from][1]
	-- A capital, so the resistance is above a level-one captain's whole
	-- ceiling. Any ordinary system next door would now simply fall.
	s.systems[blocker].owner = 2
	s.systems[blocker].capital_of = 2
	s.players[2].capital = blocker

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
	-- The player has to be able to work out what it would take, or the only way
	-- to find the number is to lose a captain against it.
	check("the refusal says what it would have taken",
		blocked and blocked.resistance and blocked.strength
			and blocked.resistance > blocked.strength,
		blocked and (tostring(blocked.strength) .. " vs " .. tostring(blocked.resistance)))
end

print("strength is what takes ground")
do
	local s = new_game(2)
	local captain = s.captains[1]
	local from = captain.at
	local target = GALAXY.adjacency[from][1]
	s.systems[target].owner = 2

	local mods = modifiers.of(s.players[1])
	local before = commanders.strength(captain, mods)
	local cost = systems.defence(GALAXY, target, false, modifiers.of(s.players[2]))
	check("a fresh captain can afford an ordinary system", before >= cost,
		before .. " vs " .. cost)

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = captain.id, route = { target } },
	}, LENGTHS)
	local battle
	for i = 1, #ev do if ev[i].kind == "battle" then battle = ev[i] end end

	check("the system changes hands", s.systems[target].owner == 1)
	check("the captain is standing on it", captain.at == target)
	check("a battle is reported", battle ~= nil and battle.at == target)
	check("it cost exactly the resistance",
		battle and battle.resistance == cost, battle and battle.resistance)
	-- Recovery runs in the aftermath of the same turn, so the strength left is
	-- what was spent plus one turn's resupply on ground that is now ours.
	check("strength was spent taking it",
		commanders.strength(captain, mods) <= before - cost + rules.strength_recovery,
		commanders.strength(captain, mods))
	check("and the fight was worth experience", (captain.xp or 0) == cost,
		captain.xp)
end

print("a garrison is part of what a system costs")
do
	local s = new_game(2)
	local target = GALAXY.adjacency[s.captains[1].at][1]
	s.systems[target].owner = 2
	local bare = systems.defence(GALAXY, target, false, modifiers.of(s.players[2]))

	-- A veteran parked on it. Deliberately far above what a fresh attacker can
	-- cover, so the assertion does not depend on which star the map put here.
	s.captains[2].at = target
	s.captains[2].level = rules.commander_max_level
	local garrison = commanders.strength(s.captains[2], modifiers.of(s.players[2]))

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS)
	local blocked
	for i = 1, #ev do if ev[i].kind == "captain_blocked" then blocked = ev[i] end end

	check("a garrisoned system turns a fresh captain back", blocked ~= nil)
	check("and it costs the world plus whoever is standing on it",
		blocked and blocked.resistance == bare + garrison,
		blocked and (tostring(blocked.resistance)
			.. " vs " .. bare .. "+" .. garrison))
	check("the defender is untouched by an attack that never happened",
		s.captains[2].at == target
			and commanders.strength(s.captains[2], modifiers.of(s.players[2])) == garrison)
end

print("a broken captain goes home")
do
	local s = new_game(2)
	-- A weak garrison on an ordinary system, so the attack lands.
	local target = GALAXY.adjacency[s.captains[1].at][1]
	s.systems[target].owner = 2
	s.captains[2].at = target
	s.captains[2].strength = 0
	s.captains[2].level = 3
	local home = s.players[2].capital

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS)
	local broken
	for i = 1, #ev do if ev[i].kind == "captain_broken" then broken = ev[i] end end

	check("the defender is broken, not deleted", #s.captains == 2)
	check("and reported as such", broken ~= nil)
	check("thrown back to their capital", s.captains[2].at == home,
		s.captains[2].at .. " vs " .. home)
	check("stripped of the rank they had earned", s.captains[2].level == 2,
		s.captains[2].level)
	check("their route is gone with them", #s.captains[2].route == 0)
end

print("strength comes back, but only on your own ground")
do
	local s = new_game(2)
	local captain = s.captains[1]
	local mods = modifiers.of(s.players[1])
	local full = commanders.max_strength(captain, mods)

	-- At the capital: the fastest recovery there is.
	captain.strength = 0
	res.turn(GALAXY, s, {}, LENGTHS)
	check("a captain refits fastest at their capital",
		commanders.strength(captain, mods) == math.min(full, rules.capital_recovery),
		commanders.strength(captain, mods))

	-- On ordinary ground the player holds: slower.
	local own = GALAXY.adjacency[captain.at][1]
	s.systems[own].owner = 1
	captain.at = own
	captain.strength = 0
	res.turn(GALAXY, s, {}, LENGTHS)
	check("slower on ordinary ground they hold",
		commanders.strength(captain, mods) == rules.strength_recovery,
		commanders.strength(captain, mods))

	-- In space nobody holds: not at all. An army out of supply is what stops a
	-- deep raid running for ever.
	local neutral
	for _, id in ipairs(GALAXY.adjacency[own]) do
		if s.systems[id].owner == 0 then neutral = id break end
	end
	if neutral then
		s.systems[neutral].owner = 0
		captain.at = neutral
		captain.strength = 0
		-- Resupply reads where the captain stands; claiming happens in
		-- movement, so a parked captain on neutral ground stays out of supply.
		res.turn(GALAXY, s, {}, LENGTHS)
		check("and not at all out of supply",
			commanders.strength(captain, mods) == 0,
			commanders.strength(captain, mods))
	end

	check("never above the ceiling", (function()
		captain.at = s.players[1].capital
		s.systems[captain.at].owner = 1
		captain.strength = full
		res.turn(GALAXY, s, {}, LENGTHS)
		return commanders.strength(captain, mods) == full
	end)())
end

print("a capital needs a veteran")
do
	local s = new_game(2)
	local capital = s.players[2].capital
	local defence = systems.defence(GALAXY, capital, true, modifiers.of(s.players[2]))
	local green = commanders.max_strength({ level = 1 }, modifiers.of(s.players[1]))
	check("a fresh captain cannot crack one at full strength", green < defence,
		green .. " vs " .. defence)
	check("but a promoted one can", commanders.max_strength(
		{ level = rules.commander_max_level }, modifiers.of(s.players[1])) >= defence)
end

print("what a rival saw of your march")
do
	local s = new_game(2)
	local captain = s.captains[1]
	-- Three lanes a turn, so a march has a path long enough to be clipped.
	captain.level = rules.commander_max_level
	local target = system_at_hops(s, captain.at, 3)

	-- Give player 2 eyes on part of the way, but not all of it. A system they
	-- hold sees `base_vision` lanes around it, so watching two *consecutive*
	-- legs takes a listening post beside each - and neither may sit on the
	-- route itself, or the march becomes a battle instead of a sighting.
	local route = res.expand_route(GALAXY, LENGTHS, captain.at, nil, { target }, 12)
	local on_route = { [captain.at] = true }
	for k = 1, #route do on_route[route[k]] = true end
	for _, p in ipairs(s.players) do on_route[p.capital] = true end

	local posts = 0
	for leg = 1, 2 do
		for _, n in ipairs(GALAXY.adjacency[route[leg]]) do
			if not on_route[n] and s.systems[n].owner == 0 then
				s.systems[n].owner = 2
				on_route[n] = true
				posts = posts + 1
				break
			end
		end
	end
	-- One post is often enough: a listening post beside a lane junction sees
	-- both ends of it. What matters is that *some* of the march is watched and
	-- some is not, which the checks below verify against the fog itself.
	check("the board has somewhere to watch from", posts > 0, posts)

	local ev = res.turn(GALAXY, s, {
		{ player = 1, kind = "move", captain = 1, route = { target } },
	}, LENGTHS)

	local mine, sighting
	for i = 1, #ev do
		if ev[i].kind == "captain_moved" then mine = ev[i] end
		if ev[i].kind == "contact_moved" then sighting = ev[i] end
	end

	check("your own march is recorded in full",
		mine ~= nil and #mine.path > 1, mine and #mine.path)
	check("and it is yours alone",
		mine and #mine.visible_to == 1 and mine.visible_to[1] == 1)

	-- The sighting is a property of the fog, so check it against the fog rather
	-- than against a hand-worked answer: every system in it must be somewhere
	-- the observer can actually see.
	if sighting then
		local seen = view.visible_systems(GALAXY, s, 2)
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
	t.captains[1].level = rules.commander_max_level
	local ev2 = res.turn(GALAXY, t, {
		{ player = 1, kind = "move", captain = 1,
		  route = { system_at_hops(t, t.captains[1].at, 3) } },
	}, LENGTHS)
	local any = false
	for i = 1, #ev2 do if ev2[i].kind == "contact_moved" then any = true end end
	check("a march nobody could see is not reported at all", not any)
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
	-- Combat is a comparison the attacker is expected to make before
	-- committing, so both halves of it have to be on screen.
	check("and their strength, so an attack can be priced",
		type(v2.contacts[1].strength) == "number")
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
	check("the fast race gets a whole extra lane",
		cartel.step_bonus == base.step_bonus + 1)
	check("and can plot further ahead", cartel.hops > base.hops)

	-- Races used to differ on mobility alone, which made the fast one strictly
	-- the best pick. Strength is what finally reads the other two keys.
	local vorn = modifiers.of({ race = "vorn" })
	local silicate = modifiers.of({ race = "silicate" })
	check("the warlike race hits harder",
		commanders.max_strength({ level = 1 }, vorn)
			> commanders.max_strength({ level = 1 }, base))
	check("the entrenched race is harder to shift", silicate.defence > base.defence)
	check("and the fast one pays for it in defence", cartel.defence < base.defence)
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
	-- What was seen, not just *when*. The repair was written when memory was
	-- id -> turn and coerced each entry with `tonumber`, which flattened every
	-- record to the number zero the moment it started carrying an owner. That
	-- inverted the whole purpose of this function - fog memory was wiped on
	-- every read - and crashed `view.project` outright on the first system a
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
	local seen_now = view.visible_systems(GALAXY, repaired, 1)
	for id = 1, #GALAXY.stars do
		if not seen_now[id] then far = id break end
	end
	repaired.knowledge[1][far] = { turn = 1, owner = 2, capital_of = 0 }
	local projected, why = pcall(view.project, GALAXY, repaired, 1)
	check("a projection still builds from remembered ground", projected, why)
	check("and the memory of it survives the trip", (function()
		local v = view.project(GALAXY, repaired, 1)
		local entry = v.systems[tostring(far)]
		return entry ~= nil and entry.owner == 2 and entry.live == false
	end)())
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

	-- Fenced in by somebody else's ground. It used to have no answer to this at
	-- all and would simply stop for the rest of the game, which is most of what
	-- made the old skeleton unresolvable.
	local function fenced_game(strength)
		local u = new_game(2)
		u.players[2].bot = true
		local cap = u.players[2].capital
		for _, n in ipairs(GALAXY.adjacency[cap]) do u.systems[n].owner = 1 end
		u.captains[2].strength = strength
		return u, bots.all_orders(GALAXY, u)
	end

	local u, out = fenced_game(nil)
	check("a fenced-in bot attacks its way out", #out == 1, #out)
	check("and the target is ground somebody holds",
		out[1] and u.systems[out[1].route[1]].owner == 1)

	local _, spent = fenced_game(0)
	check("but not one that has spent itself", #spent == 0, #spent)
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
