-- Play a whole game with a simple AI, to see whether it is a game at all.
--
-- Usage: luajit tools/play.lua [seed] [players] [max_turns] [star_count] [quiet]
--
-- The AI does one thing, because there is currently one thing to do: send its
-- captain at the nearest system it does not own. That is enough to answer the
-- question this tool exists for - does the map fill, do borders form, and does
-- anyone ever hold enough regions to win.

package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local path = require("galaxy.sim.path")
local races = require("galaxy.sim.races")
local regions = require("galaxy.sim.regions")
local systems = require("galaxy.sim.systems")
local bots = require("galaxy.sim.bots")
local config = require("galaxy.config")

local seed = tonumber(arg[1]) or 1337
local player_count = tonumber(arg[2]) or 4
local max_turns = tonumber(arg[3]) or 400
local star_count = tonumber(arg[4])
local quiet = arg[5] == "quiet"

if star_count then config.star_count = star_count end

local t0 = os.clock()
local galaxy = gen.build(seed)

local race_ids = races.ids()
local players = {}
for i = 1, player_count do
	players[i] = { id = "ai" .. i, name = bots.name(i),
		race = race_ids[((i - 1) % #race_ids) + 1], bot = true }
end
local state = st.new(galaxy, players)

-- The AI is `galaxy/sim/bots.lua` - the same code the server runs. An AI that
-- only existed in this harness would be the one nobody plays against, and the
-- one that ships would be the one nobody tests.

local census = systems.census(galaxy)
if not quiet then
	print(string.format(
		"seed %d: %d stars (%d colonies, %d outposts, %d waypoints), %d players",
		seed, #galaxy.stars, census.colony, census.outpost, census.waypoint,
		player_count))
	print(string.format("%d regions; %d of them wins",
		#galaxy.regions, regions.needed(galaxy)))
end

local winner, decided_turn = nil, nil
local events_total = 0

for turn = 1, max_turns do
	local orders = bots.all_orders(galaxy, state)
	local events = res.turn(galaxy, state, orders)
	events_total = events_total + #events

	if not quiet and (turn % 25 == 0 or turn == 1) then
		local cells = {}
		for i = 1, #state.players do
			cells[i] = string.format("%3d", st.holdings_of(state, i))
		end
		print(string.format("%-6d %s", turn, table.concat(cells, " ")))
	end

	if state.winner then
		winner, decided_turn = state.winner, turn
		break
	end
	local alive = 0
	for i = 1, #state.players do
		if state.players[i].alive then alive = alive + 1 end
	end
	if alive <= 1 then break end
end

local elapsed = (os.clock() - t0) * 1000
local tally = regions.tally(galaxy, state)
local needed = regions.needed(galaxy)

print()
for i = 1, #state.players do
	-- An eliminated player has no captains at all: their empire falls open and
	-- their officers leave the board with it.
	local captain = st.captains_of(state, i)[1]
	print(string.format("  %-19s %-9s regions %2d/%-2d  systems %3d  captain %s",
		state.players[i].name, state.players[i].race, tally[i] or 0, needed,
		st.holdings_of(state, i),
		captain and ("at " .. captain.at) or "-- out --"))
end

local claimed = 0
for _, sys in pairs(state.systems) do if sys.owner ~= 0 then claimed = claimed + 1 end end
print()
print(string.format("decided on turn %s by AI %s",
	tostring(decided_turn), tostring(winner)))
print(string.format("%d of %d systems claimed, %d turns simulated in %.0f ms (%.2f ms/turn), %d events",
	claimed, #galaxy.stars, state.turn, elapsed,
	elapsed / math.max(1, state.turn), events_total))
print(string.format("at 2 turns/day that is about %d days of real time",
	math.floor(state.turn / 2)))
