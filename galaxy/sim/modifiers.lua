--- Race and technology, folded into the numbers the resolver actually reads.
--
-- Everywhere else in the sim there is exactly one way a bonus can exist: an
-- entry in an effect table. This is where those entries stop being data and
-- become multipliers. Keeping the fold in one place is what lets races and the
-- tech tree share a vocabulary, and means a new effect key is wired up by
-- naming it here once.
--
-- Deliberately not cached. The result is a few dozen table lookups, it is asked
-- for once per player per turn, and the alternative - caching on the player
-- record - would either be serialised into Nakama storage or go stale the turn
-- a technology completes.

local races = require("galaxy.sim.races")
local tech = require("galaxy.sim.tech")
local rules = require("galaxy.sim.rules")

local M = {}

local min = math.min

--- Sum the race's and the player's researched effects into one raw table.
--
-- A nil player is the neutral baseline rather than the default race: the tests
-- and tools/play.lua compare against it, and folding Terran's bonuses into
-- "no modifiers" would quietly make every unmodified number wrong.
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
--
-- `player` is a state.players entry; passing nil yields the unmodified
-- baseline, which is what the tests and tools/play.lua compare against.
function M.of(player)
	local e = raw_effects(player)

	return {
		-- Population
		growth       = rules.growth_rate * scale(e, "growth"),
		capacity     = scale(e, "capacity"),

		-- Shipbuilding
		industry     = rules.ships_per_pop * scale(e, "industry"),
		ship_cost    = scale(e, "ship_cost"),
		cap          = rules.fleet_cap_per_pop * scale(e, "cap"),

		-- Combat
		attack       = scale(e, "attack"),
		defence      = rules.defence_bonus * scale(e, "defence"),
		-- Share of a captured system's population that survives the taking.
		capture_keep = min(1, (1 - rules.capture_population_loss) * scale(e, "capture")),

		-- Movement
		speed        = rules.fleet_speed * scale(e, "speed"),
		upkeep       = rules.fuel_per_warship * scale(e, "upkeep"),
		hops         = rules.max_path_hops + (e.hops or 0),

		-- Income
		yield_metal    = scale(e, "yield_metal"),
		yield_fuel     = scale(e, "yield_fuel"),
		yield_research = scale(e, "yield_research"),
		trade          = rules.trade_yield * scale(e, "trade"),

		-- Structural
		vision       = rules.base_vision + (e.vision or 0),
		-- Handed straight to tech.cost_of, which clamps it.
		tech_cost    = e.tech_cost or 0,
	}
end

--- Multiplier for one resource kind, by name.
function M.yield_scale(mods, kind)
	if kind == "metal" then return mods.yield_metal end
	if kind == "fuel" then return mods.yield_fuel end
	return mods.yield_research
end

return M
