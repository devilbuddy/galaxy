--- Race and technology, folded into the numbers the resolver actually reads.
--
-- Everywhere else in the sim there is exactly one way a bonus can exist: an
-- entry in an effect table. This is where those entries stop being data and
-- become multipliers. Keeping the fold in one place is what lets races and the
-- tech tree share a vocabulary, and means a new effect key is wired up by naming
-- it here once.
--
-- Deliberately not cached. The result is a few dozen table lookups, it is asked
-- for once per player per turn, and the alternative - caching on the player
-- record - would either be serialised into Nakama storage or go stale the turn a
-- technology completes.

local races = require("galaxy.sim.races")
local tech = require("galaxy.sim.tech")
local rules = require("galaxy.sim.rules")

local M = {}

local min = math.min

--- Sum the race's and the player's researched effects into one raw table.
--
-- A nil player is the neutral baseline rather than the default race: the tests
-- and tools/play.lua compare against it, and folding Terran's bonuses into "no
-- modifiers" would quietly make every unmodified number wrong.
local function raw_effects(player)
	local out = {}
	if not player then return out end
	local race = races.by_id(player.race)
	for key, value in pairs(race.mods) do
		out[key] = (out[key] or 0) + value
	end
	if type(player.tech) == "table" then
		tech.effects_of(player.tech, out)
	end
	return out
end

-- A modifier can halve something but never invert it: at -1.0 a multiplier
-- reaches zero and below that the sign flips, which would turn "cheaper ships"
-- into ships that pay you.
local function scale(effects, key)
	local v = 1 + (effects[key] or 0)
	if v < 0.05 then v = 0.05 end
	return v
end

--- The effective numbers for one player.
function M.of(player)
	local e = raw_effects(player)

	return {
		-- Population
		growth       = rules.growth_rate * scale(e, "growth"),
		capacity     = scale(e, "capacity"),

		-- Output
		industry     = scale(e, "industry"),
		ship_cost    = rules.ship_cost * scale(e, "ship_cost"),
		research     = scale(e, "research"),
		cap          = rules.fleet_cap_per_pop * scale(e, "cap"),
		-- Handed to buildings.cost, which clamps it.
		building_cost = e.building_cost or 0,

		-- Command. Scales what a commander of a given level may lead, and how
		-- much their presence is worth in a battle.
		command      = scale(e, "command"),
		tactics      = scale(e, "tactics"),

		-- Combat
		attack       = scale(e, "attack"),
		defence      = rules.defence_bonus * scale(e, "defence"),
		fortress     = scale(e, "fortress"),
		-- Share of a captured world's population that survives the taking.
		capture_keep = min(1, (1 - rules.capture_population_loss) * scale(e, "capture")),

		-- Movement. A commander's own speed comes from their level
		-- (galaxy/sim/commanders.lua); this is the multiplier race and
		-- technology apply on top of it, so the two compose rather than one
		-- overriding the other.
		speed_scale  = scale(e, "speed"),
		hops         = rules.max_route_hops + (e.hops or 0),

		-- Intelligence. Extra lanes on top of whatever radar a system has.
		vision       = e.vision or 0,

		-- Handed straight to tech.cost_of, which clamps it.
		tech_cost    = e.tech_cost or 0,
	}
end

return M
