--- What kind of place a system is.
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

	local kind = M.WAYPOINT
	if star.habitable then
		kind = M.COLONY
	elseif PRODUCTIVE_FEATURE[star.feature] or PRODUCTIVE_CLASS[star.class] then
		kind = M.OUTPOST
	end

	-- `industry` and `science` are what a place *would* be good at. Nothing
	-- reads them while there is no production; they are kept because they are
	-- derived from the star's own class and feature, cost nothing to carry, and
	-- are exactly what city upgrades will be priced against.
	local profile = {
		kind = kind,
		industry = class.industry + (feature and feature.industry or 0),
		science = class.science + (feature and feature.science or 0),
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
