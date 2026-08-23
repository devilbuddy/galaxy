--- Game state: creation, and the small helpers the rest of the sim needs.
--
-- State holds only what cannot be derived. The galaxy itself is a pure function
-- of the seed, so it is never stored - it is passed in alongside the state
-- wherever the rules need geometry.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local starclass = require("galaxy.starclass")

local M = {}

--- Population ceiling for a system, from its star class.
function M.capacity(galaxy, star_id)
	local star = galaxy.stars[star_id]
	local capacity = rules.base_capacity
	if star.habitable then
		capacity = capacity * rules.habitable_capacity_bonus
	end
	-- Bigger, brighter stars support more; a black hole supports almost nobody.
	local class = starclass.by_id(star.class)
	return math.floor(capacity * (0.55 + 0.65 * (class and class.radius or 1)))
end

--- Choose `count` widely separated home systems.
--
-- Farthest-point sampling over the whole map: the first is random, each
-- subsequent one is the system farthest from every home chosen so far. Two
-- players starting as neighbours would decide the game in the first few turns.
local function pick_homes(galaxy, count, r)
	local stars = galaxy.stars
	local n = #stars
	count = count < n and count or n

	-- Start from a habitable-ish system near the middle of the pack rather than
	-- a rim straggler, so nobody opens the game already cornered.
	local first, best = 1, -math.huge
	for i = 1, n do
		local s = stars[i]
		local reach = #galaxy.adjacency[i]
		local score = reach + (s.habitable and 2 or 0) + r:float()
		if score > best then first, best = i, score end
	end

	local homes = { first }
	local nearest = {}
	for i = 1, n do
		local dx = stars[i].x - stars[first].x
		local dy = stars[i].y - stars[first].y
		nearest[i] = dx * dx + dy * dy
	end

	for _ = 2, count do
		local pick, pickd = 1, -1
		for i = 1, n do
			-- Never put two homes on the same system, and prefer connected ones.
			if nearest[i] > pickd and #galaxy.adjacency[i] > 0 then
				pick, pickd = i, nearest[i]
			end
		end
		homes[#homes + 1] = pick
		nearest[pick] = -1
		for i = 1, n do
			local dx = stars[i].x - stars[pick].x
			local dy = stars[i].y - stars[pick].y
			local d = dx * dx + dy * dy
			if d < nearest[i] and nearest[i] >= 0 then nearest[i] = d end
		end
	end
	return homes
end

--- Build the opening state for a game.
-- @param galaxy  a generated galaxy (see galaxy/generate.lua)
-- @param players array of { id = <string>, name = <string> }
function M.new(galaxy, players)
	local r = rng.stream(galaxy.seed, "homes")
	local homes = pick_homes(galaxy, #players, r)

	local state = {
		seed = galaxy.seed,
		turn = 0,
		players = {},
		systems = {},
		fleets = {},
		next_fleet_id = 1,
		-- Per-player memory of what they have seen. Fog of war without this
		-- would make the map flicker between known and unknown as fleets move.
		knowledge = {},
	}

	for i = 1, #galaxy.stars do
		state.systems[i] = { owner = 0, population = 0, ships = 0, home_of = 0 }
	end

	for i = 1, #players do
		state.players[i] = {
			id = players[i].id,
			name = players[i].name or ("Player " .. i),
			home = homes[i],
			alive = true,
		}
		local sys = state.systems[homes[i]]
		sys.owner = i
		sys.population = rules.start_population
		sys.ships = rules.start_ships
		sys.home_of = i
		state.knowledge[i] = {}
	end

	return state
end

--- Systems a player currently owns.
function M.owned_by(state, player)
	local out = {}
	for id, sys in pairs(state.systems) do
		if sys.owner == player then out[#out + 1] = id end
	end
	table.sort(out) -- pairs() order is undefined; sort for reproducibility
	return out
end

--- Is the player still in the game? A player with no systems and no fleets is out.
function M.is_alive(state, player)
	for _, sys in pairs(state.systems) do
		if sys.owner == player then return true end
	end
	for i = 1, #state.fleets do
		if state.fleets[i].owner == player then return true end
	end
	return false
end

return M
