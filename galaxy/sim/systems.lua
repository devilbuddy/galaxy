--- What kind of place a system is, and what it can do.
--
-- The generator already gives every system a star class, a feature and a
-- habitability flag, all of it public map data. This turns those into three
-- *kinds* of place rather than one kind with different multipliers, which is
-- what gives the map objectives and terrain instead of 220 interchangeable
-- things to own:
--
--   colony    Habitable. Holds population, hosts every building, and produces
--             in proportion to how many people live there. These are the
--             prizes - roughly a fifth of the map.
--   outpost   A productive feature or an energetic star: asteroid fields,
--             precursor ruins, jump relays, pulsars, nebulae. No population, a
--             flat trickle of output, and it can host the military buildings
--             because a radar mast and a gun battery do not need a city.
--   waypoint  Everything else. Produces nothing, holds nothing, and is
--             therefore *terrain*: fleets stop at the first hostile system, so
--             a barren lane junction is a blockade point worth taking.
--
-- All of it is derived, never stored, so it costs nothing on the wire and a
-- player can read the value of somewhere they have never been.

local starclass = require("galaxy.starclass")
local rules = require("galaxy.sim.rules")

local M = {}

M.COLONY = "colony"
M.OUTPOST = "outpost"
M.WAYPOINT = "waypoint"

-- Features that make a barren star worth holding.
local PRODUCTIVE_FEATURE = {
	asteroids = true, anomaly = true, derelict = true,
	relay = true, ruins = true, nebula = true,
}

-- Stars energetic or strange enough to be worth a station in their own right.
local PRODUCTIVE_CLASS = {
	pulsar = true, black_hole = true, nebula = true, blue_giant = true,
}

-- Relative industrial and scientific value, per star class. A dim red dwarf is
-- an ordinary place to live; exotic objects are poor homes and good laboratories.
local CLASS_VALUE = {
	red_dwarf    = { industry = 1.00, science = 0.60 },
	orange_dwarf = { industry = 1.00, science = 0.80 },
	yellow       = { industry = 0.95, science = 1.10 },
	amber_giant  = { industry = 1.25, science = 0.70 },
	white        = { industry = 0.95, science = 1.20 },
	blue_giant   = { industry = 0.90, science = 1.15 },
	red_giant    = { industry = 1.40, science = 0.65 },
	pulsar       = { industry = 0.70, science = 1.60 },
	black_hole   = { industry = 0.60, science = 2.00 },
	nebula       = { industry = 0.80, science = 1.40 },
}

-- Features add on top. These are what turn an otherwise dull star into
-- somewhere worth a war.
local FEATURE_VALUE = {
	asteroids = { industry = 0.85, science = 0.10 },
	anomaly   = { industry = 0.05, science = 0.75 },
	derelict  = { industry = 0.45, science = 0.40 },
	relay     = { industry = 0.30, science = 0.15 },
	ruins     = { industry = 0.10, science = 1.10 },
	nebula    = { industry = 0.20, science = 0.60 },
}

--- Everything static about a system, computed once and memoised on the galaxy.
--
-- Turn resolution asks for this for every owned system every turn and the
-- answer never changes for a given seed. On gopher-lua, which walks the AST,
-- recomputing it is waste that shows up in the RPC latency.
function M.profile(galaxy, id)
	local cache = galaxy.system_profiles
	if not cache then
		cache = {}
		galaxy.system_profiles = cache
	end
	local hit = cache[id]
	if hit then return hit end

	local star = galaxy.stars[id]
	local class = CLASS_VALUE[star.class] or CLASS_VALUE.yellow
	local feature = FEATURE_VALUE[star.feature]

	local industry = class.industry + (feature and feature.industry or 0)
	local science = class.science + (feature and feature.science or 0)

	local kind = M.WAYPOINT
	if star.habitable then
		kind = M.COLONY
	elseif PRODUCTIVE_FEATURE[star.feature] or PRODUCTIVE_CLASS[star.class] then
		kind = M.OUTPOST
	end

	local capacity = 0
	if kind == M.COLONY then
		local entry = starclass.by_id(star.class)
		capacity = math.floor(rules.base_capacity
			* (0.55 + 0.65 * (entry and entry.radius or 1)))
	end

	local profile = {
		kind = kind,
		industry = industry,
		science = science,
		capacity = capacity,
		-- A waypoint produces nothing at all; that is what makes it terrain.
		productive = kind ~= M.WAYPOINT,
	}
	cache[id] = profile
	return profile
end

function M.kind(galaxy, id)
	return M.profile(galaxy, id).kind
end

function M.is_colony(galaxy, id)
	return M.profile(galaxy, id).kind == M.COLONY
end

--- Population ceiling. Only a colony has one; `mods` is the owner's modifier
--- table, and omitting it gives the ceiling an observer would estimate.
function M.capacity(galaxy, id, mods)
	local profile = M.profile(galaxy, id)
	if profile.kind ~= M.COLONY then return 0 end
	local capacity = profile.capacity
	if mods then capacity = capacity * mods.capacity end
	return math.floor(capacity)
end

--- Build points this system produces per turn.
--
-- A colony's output scales with its population, which is what makes taking one
-- worth more than taking ten waypoints; an outpost gives a flat trickle whoever
-- holds it.
function M.output(galaxy, id, sys, mods, buildings)
	local profile = M.profile(galaxy, id)
	if not profile.productive then return 0 end

	local base
	if profile.kind == M.COLONY then
		base = rules.colony_output_flat + (sys.population or 0) * rules.colony_output_per_pop
	else
		base = rules.outpost_output
	end

	local scale = profile.industry
	if buildings then
		scale = scale * (1 + rules.shipyard_bonus * (buildings.shipyard or 0))
	end
	if mods then scale = scale * mods.industry end
	return base * scale
end

--- Research this system contributes per turn.
function M.research(galaxy, id, sys, mods)
	local profile = M.profile(galaxy, id)
	if not profile.productive then return 0 end

	local base
	if profile.kind == M.COLONY then
		base = (sys.population or 0) * rules.research_per_pop
	else
		base = rules.outpost_research
	end

	local scale = profile.science
	if mods then scale = scale * mods.research end
	return base * scale
end

--- What a system defends itself with, before any fleet is counted.
--
-- Population plus fortifications, so an empty colony is still not free and a
-- fortified chokepoint is a real obstacle. It is never consumed - it is the
-- floor under whatever fleets happen to be there.
function M.defence(galaxy, id, sys, buildings)
	local profile = M.profile(galaxy, id)
	local defence = 0
	if profile.kind == M.COLONY then
		defence = (sys.population or 0) * rules.planet_defence_per_pop
	end
	if buildings then
		defence = defence + rules.fortress_defence * (buildings.fortress or 0)
	end
	return defence
end

--- Lanes of vision this system grants its owner.
function M.vision(galaxy, id, buildings, mods)
	local radar = buildings and (buildings.radar or 0) or 0
	local extra = mods and mods.vision or 0
	return rules.base_vision + radar * rules.radar_vision + extra
end

--- Colonies within `hops` lanes of `from`, for the opening-position guarantee.
function M.colonies_within(galaxy, from, hops)
	local seen = { [from] = 0 }
	local frontier = { from }
	local found = M.is_colony(galaxy, from) and 1 or 0
	for _ = 1, hops do
		local next_frontier = {}
		for i = 1, #frontier do
			local neighbours = galaxy.adjacency[frontier[i]]
			for k = 1, #neighbours do
				local id = neighbours[k]
				if not seen[id] then
					seen[id] = true
					next_frontier[#next_frontier + 1] = id
					if M.is_colony(galaxy, id) then found = found + 1 end
				end
			end
		end
		frontier = next_frontier
	end
	return found
end

--- Counts by kind, for tools and tests.
function M.census(galaxy)
	local out = { colony = 0, outpost = 0, waypoint = 0 }
	for id = 1, #galaxy.stars do
		local kind = M.kind(galaxy, id)
		out[kind] = out[kind] + 1
	end
	return out
end

return M
