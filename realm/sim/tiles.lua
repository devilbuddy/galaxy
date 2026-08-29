--- What kind of place a tile is.
--
-- The generator already gives every tile a terrain, a feature and a
-- habitability flag, all of it public map data. This turns those into three
-- *kinds* of place rather than one kind with different multipliers, which is
-- what gives the map objectives instead of 220 interchangeable things to own:
--
--   city    Habitable. Holds population, hosts every building, and produces
--             in proportion to how many people live there. These are the
--             prizes - roughly a fifth of the map.
--   holding   Ground with something standing on it: old ruins, a mine, a
--             shrine, a barrow, a wild gate, a gem seam. No population, a flat
--             trickle of output, and it can host the military buildings because
--             a watchtower and a gun battery do not need a city.
--   wilds  Everything else - open country. Produces nothing, holds nothing,
--             and is therefore *ground*: a commander stops at the first hostile
--             tile, so a pass between two ranges is a blockade point worth
--             taking.
--
-- All of it is derived, never stored, so it costs nothing on the wire and a
-- player can read the value of somewhere they have never been.


local rules = require("realm.sim.rules")
local terrain = require("realm.terrain")

local M = {}

M.CITY = "city"
M.HOLDING = "holding"
M.WILDS = "wilds"

-- **A holding is exactly a tile with a feature**, and nothing else. The tile
-- map also promoted energetic tile classes, which meant a holding could exist
-- with nothing on the map to say why - a pulsar looked like any other dot. Here
-- the feature is drawn, so the glyph *is* the reason, and a player can price a
-- conquest on the far side of the map by looking at it.
--
-- The industry and science each kind is worth are not tabulated here any more:
-- they live on `realm.terrain`'s own two tables, beside the thresholds that
-- decide what ground is what. One table per fact.

--- Everything static about a tile, computed once and memoised on the realm.
--
-- Turn resolution asks for this for every owned tile every turn and the
-- answer never changes for a given seed. On gopher-lua, which walks the AST,
-- recomputing it is waste that shows up in the RPC latency.
function M.profile(realm, id)
	local cache = realm.tile_profiles
	if not cache then
		cache = {}
		realm.tile_profiles = cache
	end
	local hit = cache[id]
	if hit then return hit end

	local tile = realm.tiles[id]
	local ground = terrain.by_id(tile.terrain) or terrain.TERRAIN[1]
	local feature = terrain.feature_by_id(tile.feature)

	local kind = M.WILDS
	if tile.habitable then
		kind = M.CITY
	elseif terrain.productive_feature(tile.feature) then
		kind = M.HOLDING
	end

	-- `industry` and `science` are what a place *would* be good at. Nothing
	-- reads them while there is no production; they are kept because they are
	-- derived from the tile's own class and feature, cost nothing to carry, and
	-- are exactly what city upgrades will be priced against.
	local profile = {
		kind = kind,
		industry = ground.industry + (feature and feature.industry or 0),
		science = ground.science + (feature and feature.science or 0),
		-- Open country produces nothing at all; that is what makes it terrain.
		productive = kind ~= M.WILDS,
	}
	cache[id] = profile
	return profile
end

function M.kind(realm, id)
	return M.profile(realm, id).kind
end

--- What it costs a commander to take this tile from whoever holds it.
--
-- Derived from the tile, like everything else here, so it is **public**: the
-- client computes it from the same tables rather than being told, and a player
-- can price a conquest on the far side of the realm before setting out. That
-- is the whole reason combat is a single visible comparison - see
-- `rules.defence`.
--
-- `seat` and `mods` are the two things that are not map data: whose seat
-- it is, and what its owner's race does to how hard they are to shift. Both are
-- already in the player's view of the game.
--
-- Rounded to a whole number because a fraction here would be exactly the
-- invisible arithmetic discrete movement was introduced to get rid of.
function M.defence(realm, id, seat, mods)
	local base = rules.defence[M.kind(realm, id)] or 0
	if seat then base = base + rules.seat_defence end
	local scale = (mods and mods.defence) or 1
	return math.floor(base * scale + 0.5)
end

--- Gold a tile pays its owner each turn.
--
-- The tile's own `industry` finally reads for something. It has been derived
-- from the class and feature since the generator was written and used by
-- nothing, which is why it survived the rebuild: it is exactly the number a
-- tile's worth should be priced against.
--
-- A whole number, and never less than one where a kind pays at all, so the
-- sheet can state it without a decimal. **Open country pays nothing** - see
-- `rules.gold_yield`.
--
-- `seat` is the one input that is not map data, exactly as it is for
-- `defence`: whose seat this is, which the state knows and the realm does
-- not. The bonus is flat rather than scaled, because it is a civic fact about
-- being somebody's seat and not a fact about the tile.
function M.yield(realm, id, seat)
	local profile = M.profile(realm, id)
	local base = rules.gold_yield[profile.kind] or 0
	local total = 0
	if base > 0 then
		total = math.max(1, math.floor(base * profile.industry + 0.5))
	end
	if seat then total = total + rules.seat_yield end
	return total
end

function M.is_city(realm, id)
	return M.profile(realm, id).kind == M.CITY
end

--- Cities within `hops` tiles of `from`, for the opening-position guarantee.
function M.cities_within(realm, from, hops)
	local seen = { [from] = 0 }
	local frontier = { from }
	local found = M.is_city(realm, from) and 1 or 0
	for _ = 1, hops do
		local next_frontier = {}
		for i = 1, #frontier do
			local neighbours = realm.adjacency[frontier[i]]
			for k = 1, #neighbours do
				local id = neighbours[k]
				if not seen[id] then
					seen[id] = true
					next_frontier[#next_frontier + 1] = id
					if M.is_city(realm, id) then found = found + 1 end
				end
			end
		end
		frontier = next_frontier
	end
	return found
end

--- Counts by kind, for tools and tests.
function M.census(realm)
	local out = { city = 0, holding = 0, wilds = 0 }
	for id = 1, #realm.tiles do
		local kind = M.kind(realm, id)
		out[kind] = out[kind] + 1
	end
	return out
end

return M
