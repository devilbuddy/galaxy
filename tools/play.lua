-- Play a whole game headlessly with a simple greedy AI.
--
-- Not a test of correctness (tools/test_sim.lua does that) but of *pacing*: a
-- rule set can be perfectly consistent and still produce a game that stalls in
-- a stalemate or is decided on turn three. Run it before touching the numbers
-- in galaxy/sim/rules.lua.
--
-- Usage: luajit tools/play.lua [seed] [players] [max_turns] [star_count] [quiet]
package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local path = require("galaxy.sim.path")
local races = require("galaxy.sim.races")
local tech = require("galaxy.sim.tech")
local systems = require("galaxy.sim.systems")
local buildings = require("galaxy.sim.buildings")

local seed = tonumber(arg[1]) or 424242
local player_count = tonumber(arg[2]) or 6
local max_turns = tonumber(arg[3]) or 400
local star_count = tonumber(arg[4]) or 160
local quiet = arg[5] == "quiet"

local galaxy = gen.build(seed, { star_count = star_count })
local lengths = path.lane_lengths(galaxy)

-- One race each, cycled, so a run exercises every stat spread rather than six
-- copies of the same empire.
local race_ids = races.ids()
local players = {}
for i = 1, player_count do
	players[i] = { id = "ai" .. i, name = "AI " .. i,
		race = race_ids[((i - 1) % #race_ids) + 1] }
end
local state = st.new(galaxy, players)

--- Target-centric expansion, now expressed as fleet orders.
--
-- Deliberately concentrates: for each frontier system it sums the parked fleets
-- available from *every* adjacent system it owns and commits only when the
-- combined force beats what is there. An AI that attacks one system at a time
-- simply feeds its ships to defenders and the map freezes.
local function ai_orders(player)
	local orders = {}
	local me = state.players[player]
	local owned = st.owned_by(state, player)
	local owned_set = {}
	for _, id in ipairs(owned) do owned_set[id] = true end

	-- Research whatever is cheapest. Not clever - the point of this harness is
	-- pacing, and a smart research order would make the numbers reflect the AI
	-- rather than the rules.
	if not me.researching then
		local best, best_cost = nil, math.huge
		for _, id in ipairs(tech.available(me.tech)) do
			local cost = tech.cost_of(id, 0)
			if cost < best_cost then best, best_cost = id, cost end
		end
		if best then orders[#orders + 1] = { player = player, kind = "research", tech = best } end
	end

	-- Develop: a shipyard on every colony, then radar. Nothing clever about
	-- placement, just enough that the building layer is exercised.
	for _, id in ipairs(owned) do
		local sys = state.systems[id]
		if not sys.building then
			local want = nil
			if systems.is_colony(galaxy, id) and (sys.buildings.shipyard or 0) < 2 then
				want = "shipyard"
			elseif (sys.buildings.radar or 0) < 1 then
				want = "radar"
			end
			if want and buildings.can_start(galaxy, id, sys, want) then
				orders[#orders + 1] = { player = player, kind = "build",
					at = id, building = want }
			end
		end
	end

	-- Anything that arrived somewhere we hold rejoins the pool. Without this the
	-- AI's ships end up stranded in parked fleets it never looks at again, and
	-- it stops expanding around turn 300 with half the map still neutral.
	for _, f in ipairs(state.fleets) do
		if f.owner == player and st.is_parked(f) then
			local sys = state.systems[f.at]
			if sys and sys.owner == player then
				orders[#orders + 1] = { player = player, kind = "garrison", fleet = f.id }
			end
		end
	end

	-- Frontier targets, and which garrisons border them. Launching out of the
	-- garrison is the AI's only fleet verb: it has no reason to keep standing
	-- forces, so this exercises launch + arrive + consolidate rather than
	-- long campaigns.
	local targets, order = {}, {}
	for _, from in ipairs(owned) do
		for _, to in ipairs(galaxy.adjacency[from]) do
			if not owned_set[to] then
				if not targets[to] then targets[to] = {}; order[#order + 1] = to end
				local list = targets[to]
				list[#list + 1] = from
			end
		end
	end
	table.sort(order)

	local committed = {}
	for _, to in ipairs(order) do
		local target = state.systems[to]
		local sources, available = {}, 0
		for _, from in ipairs(targets[to]) do
			if not committed[from] then
				-- Leave a little behind: a world stripped bare flips to the
				-- first thing that wanders past.
				local spare = math.floor(state.systems[from].ships * 0.7)
				if spare > 0 then
					sources[#sources + 1] = { from = from, ships = spare }
					available = available + spare
				end
			end
		end
		local needed = 1
		if target.owner ~= 0 then
			local def = systems.defence(galaxy, to, target, target.buildings)
			local garrison = target.ships or 0
			for _, f in ipairs(st.fleets_at(state, target.owner, to)) do
				garrison = garrison + f.ships
			end
			needed = math.ceil((garrison + def) * 1.5)
		end
		if available >= needed and available > 0 then
			for _, src in ipairs(sources) do
				committed[src.from] = true
				orders[#orders + 1] = { player = player, kind = "launch",
					at = src.from, ships = src.ships, route = { to } }
			end
		end
	end
	return orders
end

local function standings()
	local rows = {}
	for i = 1, #state.players do
		local sys_count, colonies, pop = 0, 0, 0
		for id, s in pairs(state.systems) do
			if s.owner == i then
				sys_count = sys_count + 1
				pop = pop + s.population
				if systems.is_colony(galaxy, id) then colonies = colonies + 1 end
			end
		end
		local known = 0
		for _ in pairs(state.players[i].tech) do known = known + 1 end
		local fleets = 0
		for f = 1, #state.fleets do
			if state.fleets[f].owner == i then fleets = fleets + 1 end
		end
		rows[i] = { i = i, systems = sys_count, colonies = colonies, pop = pop,
			ships = st.ships_of(state, i), fleets = fleets,
			race = state.players[i].race, tech = known,
			research = state.players[i].research }
	end
	return rows
end

local total_systems = #galaxy.stars
local census = systems.census(galaxy)
if not quiet then
	print(string.format("seed %d  %d systems (%d colonies, %d outposts, %d waypoints)  %d players",
		seed, total_systems, census.colony, census.outpost, census.waypoint, player_count))
print(string.format("%d regions; %d of them wins",
	#galaxy.regions, require("galaxy.sim.regions").needed(galaxy)))
	print(string.format("%-6s %s", "turn", "systems held by each player"))
end

local t0 = os.clock()
local winner, decided_turn = nil, nil
local events_total = 0

for turn = 1, max_turns do
	local orders = {}
	for p = 1, #state.players do
		if state.players[p].alive then
			for _, o in ipairs(ai_orders(p)) do orders[#orders + 1] = o end
		end
	end

	local events = res.turn(galaxy, state, orders, lengths)
	events_total = events_total + #events

	local rows = standings()
	if not quiet and (turn % 25 == 0 or turn == 1) then
		local cells = {}
		for i = 1, #rows do cells[i] = string.format("%3d", rows[i].systems) end
		print(string.format("%-6d %s", turn, table.concat(cells, " ")))
	end

	-- The simulation decides this now: holding enough regions wins outright
	-- (galaxy/sim/regions.lua). This used to be a "60% of systems" heuristic
	-- here, which measured a different game from the one being played.
	if state.winner then
		winner, decided_turn = state.winner, turn
		break
	end

	local alive, leader = 0, nil
	for i = 1, #rows do
		if rows[i].systems > 0 then alive = alive + 1; leader = i end
	end
	if alive <= 1 then winner, decided_turn = leader, turn break end
end

local elapsed = (os.clock() - t0) * 1000
if quiet then
	print(string.format("%3d systems  %d players  seed %-8d -> %s turns (%s)",
		total_systems, player_count, seed,
		decided_turn and tostring(decided_turn) or ">" .. max_turns,
		decided_turn and ("about " .. math.floor(decided_turn / 2) .. " days") or "no winner"))
	os.exit(0)
end
print()
local regions_mod = require("galaxy.sim.regions")
local region_tally = regions_mod.tally(galaxy, state)
local regions_needed = regions_mod.needed(galaxy)
local rows = standings()
for i = 1, #rows do
	print(string.format("  AI %-2d %-9s regions %2d/%-2d  sys %3d (%2d col)  ships %6d in %d fleets  pop %6d  tech %2d%s",
		i, rows[i].race, region_tally[i] or 0, regions_needed,
		rows[i].systems, rows[i].colonies, rows[i].ships,
		rows[i].fleets, rows[i].pop, rows[i].tech,
		rows[i].systems > 0 and "" or "  eliminated"))
end
local claimed = 0
for _, sys in pairs(state.systems) do if sys.owner ~= 0 then claimed = claimed + 1 end end
print()
print(string.format("decided on turn %s by AI %s", tostring(decided_turn), tostring(winner)))
print(string.format("%d of %d systems claimed, %d turns simulated in %.0f ms (%.2f ms/turn), %d events",
	claimed, total_systems, state.turn, elapsed, elapsed / math.max(1, state.turn), events_total))
print(string.format("at 2 turns/day that is about %.0f days of real time", state.turn / 2))
