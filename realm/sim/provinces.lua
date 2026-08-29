--- Provinces: who holds a stretch of the realm, and who wins because of it.
--
-- The map is deliberately much bigger than any one player will ever touch. With
-- a handful of commanders and two hundred tiles, most of the realm is
-- scenery - and that is the intent, not a shortfall. What it means is that
-- "tiles owned" is a poor objective: it counts the empty road a commander
-- happened to walk down alongside the world they fought for.
--
-- So the unit of contest is the **province** the generator already carved
-- (realm/graph.lua): a named, contiguous stretch of a dozen or so tiles, of
-- which only the cities and holdings are worth anything. A player holds a
-- province by holding most of what is worth holding in it, and the game is won by
-- holding enough provinces.
--
-- Nothing here is stored. Province control is a pure function of who owns what,
-- so it is recomputed rather than tracked - the same rule the rest of the sim
-- follows for anything derivable from the realm.

local tiles = require("realm.sim.tiles")
local rules = require("realm.sim.rules")

local floor = math.floor

local M = {}

--- Is this tile worth counting towards control of its province?
--
-- Wilds are not. A province is decided by the places that produce, defend or
-- see something; the barren junctions between them are road.
function M.counts(realm, id)
	local kind = tiles.profile(realm, id).kind
	return kind == tiles.CITY or kind == tiles.HOLDING
end

--- How many tiles in each province count towards its control.
--
-- Derived from the realm alone, so it is memoised on it like the tile
-- profiles are: it is the same answer for every turn of every game on a seed.
function M.weights(realm)
	if realm.province_weights then return realm.province_weights end
	local out = {}
	for i = 1, #realm.provinces do out[i] = 0 end
	for i = 1, #realm.tiles do
		if M.counts(realm, i) then
			local r = realm.tiles[i].province
			out[r] = (out[r] or 0) + 1
		end
	end
	realm.province_weights = out
	return out
end

--- Who holds each province, as an array of player index (0 for nobody).
--
-- A province falls to whoever owns **more than half** of what counts in it. A
-- plain plurality would hand a province to the first player through it while two
-- others were still fighting over the worlds that matter; requiring a majority
-- means a province changing hands is news.
--
-- Returns the control array and, alongside it, the per-province tally so a caller
-- can show how close a contest is without walking the map again.
function M.control(realm, state)
	local weights = M.weights(realm)
	local counts = {}
	for i = 1, #realm.provinces do counts[i] = {} end

	for id = 1, #realm.tiles do
		local sys = state.tiles[id]
		local owner = sys and sys.owner or 0
		if owner ~= 0 and M.counts(realm, id) then
			local r = realm.tiles[id].province
			counts[r][owner] = (counts[r][owner] or 0) + 1
		end
	end

	local held = {}
	for r = 1, #realm.provinces do
		held[r] = 0
		local total = weights[r] or 0
		if total > 0 then
			-- Iterating players by index rather than the tally by `pairs`: the
			-- answer must not depend on table order on either runtime.
			for p = 1, #state.players do
				local owned = counts[r][p] or 0
				if owned * 2 > total then held[r] = p end
			end
		end
	end
	return held, counts
end

--- How many provinces each player holds.
function M.tally(realm, state, held)
	held = held or M.control(realm, state)
	local out = {}
	for i = 1, #state.players do out[i] = 0 end
	for r = 1, #held do
		local p = held[r]
		if p ~= 0 then out[p] = (out[p] or 0) + 1 end
	end
	return out
end

--- Provinces needed to win. At least two, so a small map is still a contest.
function M.needed(realm)
	local total = #realm.provinces
	return math.max(2, floor(total * rules.victory_province_fraction + 0.5))
end

--- Does holding this tile's province pay a bonus to it?
--
-- A held province produces better than a contested one, which is what makes
-- finishing a province off worth the trouble rather than leaving one stubborn
-- holding behind and moving on.
function M.bonus(realm, held, id, owner)
	local r = realm.tiles[id].province
	if held[r] == owner and owner ~= 0 then
		return 1 + rules.province_output_bonus
	end
	return 1
end

return M
