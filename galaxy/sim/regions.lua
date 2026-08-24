--- Regions: who holds a stretch of the galaxy, and who wins because of it.
--
-- The map is deliberately much bigger than any one player will ever touch. With
-- a handful of commanders and two hundred systems, most of the galaxy is
-- scenery - and that is the intent, not a shortfall. What it means is that
-- "systems owned" is a poor objective: it counts the empty road a commander
-- happened to walk down alongside the world they fought for.
--
-- So the unit of contest is the **region** the generator already carved
-- (galaxy/graph.lua): a named, contiguous stretch of a dozen or so systems, of
-- which only the colonies and outposts are worth anything. A player holds a
-- region by holding most of what is worth holding in it, and the game is won by
-- holding enough regions.
--
-- Nothing here is stored. Region control is a pure function of who owns what,
-- so it is recomputed rather than tracked - the same rule the rest of the sim
-- follows for anything derivable from the galaxy.

local systems = require("galaxy.sim.systems")
local rules = require("galaxy.sim.rules")

local floor = math.floor

local M = {}

--- Is this system worth counting towards control of its region?
--
-- Waypoints are not. A region is decided by the places that produce, defend or
-- see something; the barren junctions between them are road.
function M.counts(galaxy, id)
	local kind = systems.profile(galaxy, id).kind
	return kind == systems.COLONY or kind == systems.OUTPOST
end

--- How many systems in each region count towards its control.
--
-- Derived from the galaxy alone, so it is memoised on it like the system
-- profiles are: it is the same answer for every turn of every game on a seed.
function M.weights(galaxy)
	if galaxy.region_weights then return galaxy.region_weights end
	local out = {}
	for i = 1, #galaxy.regions do out[i] = 0 end
	for i = 1, #galaxy.stars do
		if M.counts(galaxy, i) then
			local r = galaxy.stars[i].region
			out[r] = (out[r] or 0) + 1
		end
	end
	galaxy.region_weights = out
	return out
end

--- Who holds each region, as an array of player index (0 for nobody).
--
-- A region falls to whoever owns **more than half** of what counts in it. A
-- plain plurality would hand a region to the first player through it while two
-- others were still fighting over the worlds that matter; requiring a majority
-- means a region changing hands is news.
--
-- Returns the control array and, alongside it, the per-region tally so a caller
-- can show how close a contest is without walking the map again.
function M.control(galaxy, state)
	local weights = M.weights(galaxy)
	local counts = {}
	for i = 1, #galaxy.regions do counts[i] = {} end

	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		local owner = sys and sys.owner or 0
		if owner ~= 0 and M.counts(galaxy, id) then
			local r = galaxy.stars[id].region
			counts[r][owner] = (counts[r][owner] or 0) + 1
		end
	end

	local held = {}
	for r = 1, #galaxy.regions do
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

--- How many regions each player holds.
function M.tally(galaxy, state, held)
	held = held or M.control(galaxy, state)
	local out = {}
	for i = 1, #state.players do out[i] = 0 end
	for r = 1, #held do
		local p = held[r]
		if p ~= 0 then out[p] = (out[p] or 0) + 1 end
	end
	return out
end

--- Regions needed to win. At least two, so a small map is still a contest.
function M.needed(galaxy)
	local total = #galaxy.regions
	return math.max(2, floor(total * rules.victory_region_fraction + 0.5))
end

--- Does holding this system's region pay a bonus to it?
--
-- A held region produces better than a contested one, which is what makes
-- finishing a region off worth the trouble rather than leaving one stubborn
-- outpost behind and moving on.
function M.bonus(galaxy, held, id, owner)
	local r = galaxy.stars[id].region
	if held[r] == owner and owner ~= 0 then
		return 1 + rules.region_output_bonus
	end
	return 1
end

return M
