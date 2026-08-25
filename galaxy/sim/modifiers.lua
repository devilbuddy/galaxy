--- Race, folded into the numbers the resolver actually reads.
--
-- Everywhere else in the sim there is exactly one way a bonus can exist: an
-- entry in an effect table. This is where those entries stop being data and
-- become multipliers. Keeping the fold in one place is what lets races share a
-- vocabulary with whatever else grants effects later, and means a new key is
-- wired up by naming it here once.
--
-- **Only three keys currently do anything**: speed, hops and vision. The races
-- in galaxy/sim/races.lua still declare growth, industry, research and the rest,
-- because those are the design intent for when production is built back - but
-- until something reads them they are inert data, and races are effectively
-- distinguished by mobility alone. Worth remembering before balancing anything.
--
-- Deliberately not cached. The result is a handful of table lookups, asked for
-- once per player per turn, and a cache would either be serialised into Nakama
-- storage or go stale.

local races = require("galaxy.sim.races")
local rules = require("galaxy.sim.rules")

local M = {}

--- The race's effects as a raw table.
--
-- A nil player is the neutral baseline rather than the default race: the tests
-- compare against it, and folding Terran's bonuses into "no modifiers" would
-- quietly make every unmodified number wrong.
local function raw_effects(player)
	local out = {}
	if not player then return out end
	local race = races.by_id(player.race)
	for key, value in pairs(race.mods) do
		out[key] = (out[key] or 0) + value
	end
	return out
end

-- A modifier can halve something but never invert it: at -1.0 a multiplier
-- reaches zero, and below that the sign flips.
local function scale(effects, key)
	local v = 1 + (effects[key] or 0)
	if v < 0.05 then v = 0.05 end
	return v
end

--- Everything the resolver needs about one player, in one table.
function M.of(player)
	local e = raw_effects(player)
	return {
		-- Movement. A captain's reach comes from their rank
		-- (galaxy/sim/commanders.lua); a race with a real mobility bonus adds a
		-- whole extra lane a turn. Anything finer would be arithmetic the
		-- player cannot see, which is what discrete steps exist to avoid.
		step_bonus = ((e.speed or 0) >= rules.step_race_threshold) and 1 or 0,
		hops = rules.max_route_hops + (e.hops or 0),

		-- Intelligence. Extra lanes on top of the base.
		vision = e.vision or 0,
	}
end

return M
