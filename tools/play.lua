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

local seed = tonumber(arg[1]) or 424242
local player_count = tonumber(arg[2]) or 6
local max_turns = tonumber(arg[3]) or 400
local star_count = tonumber(arg[4])
local quiet = arg[5] == "quiet"

local galaxy = gen.build(seed, star_count and { star_count = star_count } or nil)
local lengths = path.lane_lengths(galaxy)

local players = {}
for i = 1, player_count do players[i] = { id = "ai" .. i, name = "AI " .. i } end
local state = st.new(galaxy, players)

--- Target-centric expansion.
--
-- Deliberately concentrates: for each frontier system it sums the force
-- available from *every* adjacent system it owns and commits only when the
-- combined attack beats the defence. An AI that attacks one system at a time
-- simply feeds its ships to defenders and the map freezes.
local function ai_orders(player)
	local orders = {}
	local owned = st.owned_by(state, player)
	local owned_set = {}
	for _, id in ipairs(owned) do owned_set[id] = true end

	-- Frontier targets, and which of our systems border them.
	local targets, order = {}, {}
	for _, from in ipairs(owned) do
		for _, to in ipairs(galaxy.adjacency[from]) do
			if not owned_set[to] then
				if not targets[to] then targets[to] = {}; order[#order + 1] = to end
				targets[to][#targets[to] + 1] = from
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
				local spare = math.floor(state.systems[from].ships * 0.7)
				if spare > 0 then
					sources[#sources + 1] = { from = from, ships = spare }
					available = available + spare
				end
			end
		end
		local needed = target.owner == 0 and 1 or math.ceil(target.ships * 1.45)
		if available >= needed and available > 0 then
			for _, src in ipairs(sources) do
				committed[src.from] = true
				orders[#orders + 1] = { player = player, from = src.from, to = to, ships = src.ships }
			end
		end
	end
	return orders
end

local function standings()
	local rows = {}
	for i = 1, #state.players do
		local systems, ships, pop = 0, 0, 0
		for _, sys in pairs(state.systems) do
			if sys.owner == i then
				systems = systems + 1
				ships = ships + sys.ships
				pop = pop + sys.population
			end
		end
		rows[i] = { i = i, systems = systems, ships = ships, pop = pop,
			alive = state.players[i].alive }
	end
	return rows
end

local total_systems = #galaxy.stars
if not quiet then
	print(string.format("seed %d  %d systems  %d players", seed, total_systems, player_count))
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

	local alive, leader = 0, nil
	for i = 1, #rows do
		if rows[i].systems > 0 then alive = alive + 1; leader = i end
	end
	if alive <= 1 then winner, decided_turn = leader, turn break end
	-- Domination: over 60% of the map is effectively game over.
	for i = 1, #rows do
		if rows[i].systems > total_systems * 0.6 then
			winner, decided_turn = i, turn
			break
		end
	end
	if winner then break end
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
local rows = standings()
for i = 1, #rows do
	print(string.format("  AI %-2d  systems %3d  ships %6d  population %6d  %s",
		i, rows[i].systems, rows[i].ships, rows[i].pop,
		rows[i].systems > 0 and "" or "eliminated"))
end
local claimed = 0
for _, sys in pairs(state.systems) do if sys.owner ~= 0 then claimed = claimed + 1 end end
print()
print(string.format("decided on turn %s by AI %s", tostring(decided_turn), tostring(winner)))
print(string.format("%d of %d systems claimed, %d turns simulated in %.0f ms (%.2f ms/turn), %d events",
	claimed, total_systems, state.turn, elapsed, elapsed / math.max(1, state.turn), events_total))
print(string.format("at 2 turns/day that is about %.0f days of real time", state.turn / 2))
