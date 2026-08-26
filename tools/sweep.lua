-- Price the economy by playing it, many times, with one thing changed.
--
-- Every balance number in this game has been measured rather than argued -
-- "cap 6 every 2 turns decides at ~190 turns, every turn never decides at all"
-- is a sentence that only exists because somebody ran it. This is the harness
-- that produces those sentences.
--
-- Usage:
--   luajit tools/sweep.lua "<overrides>" [seeds] [players] [max_turns]
--
-- Overrides are `;`-separated assignments, applied before the first galaxy is
-- built:
--
--   rules.garrison_cap=8          a field of galaxy/sim/rules.lua
--   berths.cost=40                a field of that building in the catalogue
--   foundry.every=2               ...including its cadence and its cap
--
-- **One variant per process, on purpose.** The modules are cached, so mutating
-- `rules` in place leaks into every later run in the same VM; a fresh process
-- per variant is slower to say and impossible to get wrong. A ten-seed
-- four-player sweep is a few seconds, so there is nothing to optimise here.
--
-- What it reports is deliberately more than "how long": a variant that decides
-- quickly while every player sits on thousands of unspendable supply has not
-- been priced correctly, it has been starved somewhere else.

package.path = "./?.lua;" .. package.path

local rules = require("galaxy.sim.rules")
local buildings = require("galaxy.sim.buildings")

local overrides = arg[1] or ""
local seed_count = tonumber(arg[2]) or 10
local player_count = tonumber(arg[3]) or 4
local max_turns = tonumber(arg[4]) or 900

-- Applied before anything else requires them, so a cost that is read at load
-- time still sees the change.
for clause in overrides:gmatch("[^;]+") do
	local target, field, sub, value =
		clause:match("^%s*([%w_]+)%.([%w_]+)%.?([%w_]*)%s*=%s*([%d%.%-]+)%s*$")
	if not target then
		io.stderr:write("cannot parse override: " .. clause .. "\n")
		os.exit(2)
	end
	value = tonumber(value)
	if target == "rules" then
		-- One level of nesting, for the tables that are themselves prices:
		-- `rules.supply_yield.colony=3`, `rules.order_cost.build=0`.
		if sub ~= "" then
			rules[field][sub] = value
		else
			rules[field] = value
		end
	else
		local spec = buildings.by_id(target)
		if not spec then
			io.stderr:write("no such building: " .. target .. "\n")
			os.exit(2)
		end
		spec[field] = value
	end
end

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local path = require("galaxy.sim.path")
local races = require("galaxy.sim.races")
local bots = require("galaxy.sim.bots")
local units = require("galaxy.sim.units")

-- A fixed spread, so two variants are always compared on the same galaxies.
local SEEDS = { 1, 7, 42, 1337, 2024, 8888, 424242, 90210, 31337, 555,
	13, 271828, 60606, 4711, 999983, 20260823, 5, 88, 314159, 77777 }

local function median(t)
	if #t == 0 then return nil end
	local c = {}
	for i = 1, #t do c[i] = t[i] end
	table.sort(c)
	local mid = math.floor(#c / 2)
	if #c % 2 == 1 then return c[mid + 1] end
	return (c[mid] + c[mid + 1]) / 2
end

local decided, first_blood, idle_supply, built_total, undecided = {}, {}, {}, {}, 0
-- Which buildings actually get raised, and how many officers anyone ends with.
-- A price nobody ever pays is not a price, and the two most likely to be wrong
-- are the dearest thing on the board and the one with no obvious use.
local raised = {}
for i = 1, #buildings.CATALOGUE do raised[buildings.CATALOGUE[i].id] = 0 end
local captains_each = {}
local race_ids = races.ids()

for s = 1, math.min(seed_count, #SEEDS) do
	local seed = SEEDS[s]
	local galaxy = gen.build(seed)
	local lengths = path.lane_lengths(galaxy)
	local players = {}
	for i = 1, player_count do
		players[i] = { id = "ai" .. i, name = bots.name(i),
			race = race_ids[((i - 1) % #race_ids) + 1], bot = true }
	end
	local state = st.new(galaxy, players)

	local won, fight = nil, nil
	for turn = 1, max_turns do
		local events = res.turn(galaxy, state, bots.all_orders(galaxy, state), lengths)
		for e = 1, #events do
			if not fight and events[e].kind == "battle" then fight = turn end
		end
		if state.winner then won = turn break end
	end

	if won then decided[#decided + 1] = won else undecided = undecided + 1 end
	if fight then first_blood[#first_blood + 1] = fight end

	-- What the map looked like when it stopped: money nobody could spend, and
	-- how much of the four slots anyone actually filled.
	local purse, built, alive = 0, 0, 0
	for i = 1, #state.players do
		if state.players[i].alive then
			purse = purse + (state.players[i].supply or 0)
			alive = alive + 1
		end
	end
	for _, sys in pairs(state.systems) do
		if sys.owner ~= 0 then
			built = built + #sys.buildings
			for b = 1, #sys.buildings do
				local id = sys.buildings[b]
				if raised[id] then raised[id] = raised[id] + 1 end
			end
		end
	end
	for i = 1, #state.players do
		if state.players[i].alive then
			local mine = 0
			for c = 1, #state.captains do
				if state.captains[c].owner == i then mine = mine + 1 end
			end
			captains_each[#captains_each + 1] = mine
		end
	end
	idle_supply[#idle_supply + 1] = math.floor(purse / math.max(1, alive))
	built_total[#built_total + 1] = built
end

local lo, hi = nil, nil
for i = 1, #decided do
	lo = (not lo or decided[i] < lo) and decided[i] or lo
	hi = (not hi or decided[i] > hi) and decided[i] or hi
end

print(string.format(
	"%-46s decided %2d/%2d  median %-6s range %s-%s  first fight %-5s  idle %-6s built %s",
	(overrides ~= "" and overrides or "(baseline)"),
	#decided, #decided + undecided,
	tostring(median(decided) or "-"),
	tostring(lo or "-"), tostring(hi or "-"),
	tostring(median(first_blood) or "-"),
	tostring(median(idle_supply) or "-"),
	tostring(median(built_total) or "-")))

local parts = {}
for i = 1, #buildings.CATALOGUE do
	local id = buildings.CATALOGUE[i].id
	parts[#parts + 1] = string.format("%s %d", id, raised[id])
end
print("    raised: " .. table.concat(parts, "  ")
	.. "   captains/player median " .. tostring(median(captains_each) or "-"))
