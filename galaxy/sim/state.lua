--- Game state: creation, and the small helpers the rest of the sim needs.
--
-- State holds only what cannot be derived. The galaxy itself is a pure function
-- of the seed, so it is never stored - it is passed in alongside the state
-- wherever the rules need geometry. Likewise a system's resource yields come
-- from its star class and feature, so they are computed, never stored.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local races = require("galaxy.sim.races")
local tech = require("galaxy.sim.tech")
local resources = require("galaxy.sim.resources")
local starclass = require("galaxy.starclass")

local M = {}

--- Population ceiling for a system, from its star class.
-- `mods` is the owner's modifier table (galaxy/sim/modifiers.lua); omitting it
-- gives the unmodified ceiling, which is what an observer sees.
function M.capacity(galaxy, star_id, mods)
	local star = galaxy.stars[star_id]
	local capacity = rules.base_capacity
	if star.habitable then
		capacity = capacity * rules.habitable_capacity_bonus
	end
	-- Bigger, brighter stars support more; a black hole supports almost nobody.
	local class = starclass.by_id(star.class)
	capacity = capacity * (0.55 + 0.65 * (class and class.radius or 1))
	if mods then capacity = capacity * mods.capacity end
	return math.floor(capacity)
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
-- @param players array of { id = <string>, name = <string>, race = <string> }
function M.new(galaxy, players)
	local r = rng.stream(galaxy.seed, "homes")
	local homes = pick_homes(galaxy, #players, r)

	local state = {
		seed = galaxy.seed,
		turn = 0,
		players = {},
		systems = {},
		fleets = {},
		-- Established trade routes, as { owner, a, b, ships, length }.
		routes = {},
		next_fleet_id = 1,
		-- Per-player memory of what they have seen. Fog of war without this
		-- would make the map flicker between known and unknown as fleets move.
		knowledge = {},
	}

	for i = 1, #galaxy.stars do
		state.systems[i] = { owner = 0, population = 0, ships = 0, freighters = 0, home_of = 0 }
	end

	for i = 1, #players do
		local wanted = players[i].race
		state.players[i] = {
			id = players[i].id,
			name = players[i].name or ("Player " .. i),
			-- An unrecognised or missing pick becomes the neutral race rather
			-- than failing the game start; the lobby is where a bad pick should
			-- be caught, not turn resolution.
			race = races.exists(wanted) and wanted or races.DEFAULT,
			home = homes[i],
			alive = true,
			stock = resources.normalise(rules.start_stock),
			tech = {},
			-- The technology this player is buying next. Research accumulates in
			-- the stockpile and the purchase happens the moment it is
			-- affordable, so "what am I researching" is one standing decision
			-- rather than a per-turn allocation - which is the right shape for a
			-- game checked twice a day.
			researching = nil,
			-- Share of each system's build capacity that goes to warships; the
			-- rest becomes freighters.
			warship_share = 1.0,
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

--- Total population across everything a player holds.
function M.population_of(state, player)
	local total = 0
	for _, sys in pairs(state.systems) do
		if sys.owner == player then total = total + sys.population end
	end
	return total
end

--- Warships a player has, in systems and in transit.
function M.warships_of(state, player)
	local total = 0
	for _, sys in pairs(state.systems) do
		if sys.owner == player then total = total + sys.ships end
	end
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if f.owner == player and f.kind ~= "trade" then total = total + f.ships end
	end
	return total
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

--- Bring a state read back from storage up to the shape the resolver expects.
--
-- Two jobs. New fields are filled in, so a game started before a rule existed
-- keeps working instead of erroring on a nil index. And anything that went
-- through JSON is re-typed: numbers arrive as strings from some encoders, an
-- empty set can come back as an array, and `tech` in particular is a sparse
-- string-keyed table, which is exactly the shape that survives least well.
function M.migrate(state)
	if type(state) ~= "table" then return state end
	state.fleets = state.fleets or {}
	state.routes = state.routes or {}
	state.next_fleet_id = tonumber(state.next_fleet_id) or 1

	for i = 1, #(state.players or {}) do
		local p = state.players[i]
		p.race = races.exists(p.race) and p.race or races.DEFAULT
		p.stock = resources.normalise(p.stock)
		p.tech = tech.normalise_known(p.tech)
		if p.researching == "" then p.researching = nil end
		if p.researching and not tech.by_id(p.researching) then p.researching = nil end
		local share = tonumber(p.warship_share)
		if not share then share = 1.0 end
		if share < 0 then share = 0 end
		if share > 1 then share = 1 end
		p.warship_share = share
	end

	for _, sys in pairs(state.systems or {}) do
		sys.freighters = tonumber(sys.freighters) or 0
	end

	for i = 1, #state.routes do
		local route = state.routes[i]
		route.ships = tonumber(route.ships) or 0
		route.length = tonumber(route.length) or 0
	end

	return state
end

return M
