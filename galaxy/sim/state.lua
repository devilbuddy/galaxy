--- Game state: creation, and the small helpers the rest of the sim needs.
--
-- State holds only what cannot be derived. The galaxy is a pure function of the
-- seed, so it is never stored, and neither is anything computed from it - what
-- kind of place a system is, what it can produce, what it defends itself with
-- (see galaxy/sim/systems.lua) are all recomputed on demand.
--
-- Ships live in one of two places, and the split is the whole point:
--
--   * a system's **garrison** is where production accumulates. It defends
--     alongside the world's own guns and it never moves.
--   * a **fleet** is a force under a named commander: it sits at a system or
--     partway along a lane, carries a route, and survives arriving somewhere.
--     One record holds both, because in this game the officer and the ships
--     they lead never exist apart - see galaxy/sim/commanders.lua for the
--     commander half of it.
--
-- Fleets-only was tried first and does not work: production has to land
-- somewhere, so it creates a fleet wherever there is not one, and a 400-turn
-- run ended with one empire holding a hundred and sixty of them. Making the
-- player raise one deliberately bounds the list to forces they actually care
-- about, and it turns "strip a border world to mount an attack" into an
-- explicit decision rather than an accident. `rules.commander_cap` finishes the
-- job: past a handful, which fronts to fight on stops being a choice.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local races = require("galaxy.sim.races")
local tech = require("galaxy.sim.tech")
local systems = require("galaxy.sim.systems")
local buildings = require("galaxy.sim.buildings")
local commanders = require("galaxy.sim.commanders")

local M = {}

-- Naming ----------------------------------------------------------------------

local ORDINAL_EXCEPTION = { [11] = "th", [12] = "th", [13] = "th" }
local ORDINAL_SUFFIX = { [1] = "st", [2] = "nd", [3] = "rd" }

--- "1st", "2nd", "3rd", "11th".
function M.ordinal(n)
	local suffix = ORDINAL_EXCEPTION[n % 100] or ORDINAL_SUFFIX[n % 10] or "th"
	return n .. suffix
end

--- A force is named for the officer leading it.
--
-- It used to be "3rd Fleet", which is accurate and forgettable. A player will
-- not mourn the 3rd Fleet; they will mourn Admiral Kess, who took two worlds
-- and then died at one, and that difference is most of what a commander layer
-- is for.
function M.fleet_name(player)
	return commanders.name(player)
end

-- Opening position -------------------------------------------------------------

--- Choose `count` widely separated homes, each with somewhere to expand into.
--
-- Farthest-point sampling over the *colonies* only, because a home has to hold
-- population. And every home must have a few more colonies within reach: with
-- colonies a fifth of the map and clustered by the spiral density, a player who
-- spawns in a barren arm has lost at generation rather than in play.
local function pick_homes(galaxy, count, r)
	local stars = galaxy.stars
	local n = #stars

	-- Candidates, best first: a well-connected colony with neighbours worth
	-- taking. The random tiebreak keeps two games on the same seed from opening
	-- identically only if the player count differs.
	local candidates = {}
	for i = 1, n do
		if systems.is_colony(galaxy, i) and #galaxy.adjacency[i] > 0 then
			local nearby = systems.colonies_within(galaxy, i, rules.home_colony_hops)
			candidates[#candidates + 1] = {
				id = i,
				nearby = nearby,
				score = nearby * 10 + #galaxy.adjacency[i] + r:float(),
			}
		end
	end
	table.sort(candidates, function(p, q)
		if p.score ~= q.score then return p.score > q.score end
		return p.id < q.id
	end)

	-- Prefer candidates that clear the room-to-expand bar, but never fail to
	-- place a player: a crowded map is better than no game.
	local pool = {}
	for i = 1, #candidates do
		if candidates[i].nearby >= rules.home_colony_minimum then
			pool[#pool + 1] = candidates[i].id
		end
	end
	if #pool < count then
		for i = 1, #candidates do
			local id = candidates[i].id
			local already = false
			for k = 1, #pool do
				if pool[k] == id then already = true break end
			end
			if not already then pool[#pool + 1] = id end
			if #pool >= count then break end
		end
	end
	if #pool == 0 then
		-- No colonies at all. Should not happen with the generator's floor, but
		-- a game that cannot start is worse than a game on bad ground.
		for i = 1, n do pool[#pool + 1] = i end
	end

	-- Then spread: the first is the best candidate, each subsequent one is the
	-- pool entry farthest from every home chosen so far. Two players opening as
	-- neighbours would decide the game in the first few turns.
	local homes = { pool[1] }
	local nearest = {}
	for i = 1, #pool do
		local dx = stars[pool[i]].x - stars[pool[1]].x
		local dy = stars[pool[i]].y - stars[pool[1]].y
		nearest[i] = dx * dx + dy * dy
	end

	while #homes < count do
		local pick, pickd = nil, -1
		for i = 1, #pool do
			if nearest[i] > pickd then pick, pickd = i, nearest[i] end
		end
		if not pick then break end
		homes[#homes + 1] = pool[pick]
		nearest[pick] = -1
		for i = 1, #pool do
			if nearest[i] >= 0 then
				local dx = stars[pool[i]].x - stars[pool[pick]].x
				local dy = stars[pool[i]].y - stars[pool[pick]].y
				local d = dx * dx + dy * dy
				if d < nearest[i] then nearest[i] = d end
			end
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
		next_fleet_id = 1,
		-- Per-player memory of what they have seen. Fog of war without this
		-- would make the map flicker between known and unknown as fleets move.
		knowledge = {},
	}

	for i = 1, #galaxy.stars do
		state.systems[i] = {
			owner = 0,
			population = 0,
			-- Immobile. Defends, accumulates production, and is what a fleet is
			-- launched out of.
			ships = 0,
			buildings = buildings.zero(),
			-- { kind =, paid = } while something is going up here.
			building = nil,
			home_of = 0,
		}
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
			research = 0,
			tech = {},
			-- The technology being bought next. Research pools and the purchase
			-- happens the moment it is affordable, so this is one standing
			-- decision rather than a per-turn allocation.
			researching = nil,
			next_commander_number = 1,
		}
		local home = homes[i]
		local sys = state.systems[home]
		sys.owner = i
		sys.population = rules.start_population
		sys.ships = rules.start_ships
		sys.home_of = i
		state.knowledge[i] = {}
	end

	return state
end

-- Fleets -----------------------------------------------------------------------

--- How many forces this player has in the field.
function M.commander_count(state, owner)
	local n = 0
	for i = 1, #state.fleets do
		if state.fleets[i].owner == owner then n = n + 1 end
	end
	return n
end

--- May this player raise another? The cap is what makes the answer sometimes no.
function M.can_raise(state, owner)
	return M.commander_count(state, owner) < rules.commander_cap
end

--- Take the most experienced officer off the reserve list, or nil.
local function from_reserve(player)
	local reserve = player.reserve
	if not reserve or #reserve == 0 then return nil end
	local best = 1
	for i = 2, #reserve do
		local a, b = reserve[i], reserve[best]
		-- Level first, then experience, then the order they were raised in:
		-- three tie-breaks deep so the choice never depends on table order.
		if a.level > b.level
			or (a.level == b.level and a.xp > b.xp)
			or (a.level == b.level and a.xp == b.xp and a.number < b.number) then
			best = i
		end
	end
	return table.remove(reserve, best)
end

--- Stand a force down: the ships join the garrison, the officer goes on the
--- reserve list keeping everything they earned.
---
--- Retiring rather than dismissing is the point. A player who has to choose
--- which of four fronts to give up should not also lose the rank that officer
--- spent forty turns earning - that would make standing down unthinkable, and
--- the cap would stop being a decision and start being a trap.
function M.retire_fleet(state, fleet)
	local player = state.players[fleet.owner]
	player.reserve = player.reserve or {}
	player.reserve[#player.reserve + 1] = {
		name = fleet.name, level = fleet.level or 1, xp = fleet.xp or 0,
		number = fleet.number or 0,
	}
	local surviving = {}
	for i = 1, #state.fleets do
		if state.fleets[i] ~= fleet then surviving[#surviving + 1] = state.fleets[i] end
	end
	state.fleets = surviving
end

--- Raise a commander and put them at the head of a force parked at `at`.
---
--- An officer on the reserve list is recalled before a new one is raised, so a
--- veteran stood down last week is the one who comes back.
function M.add_fleet(state, owner, at, ships)
	local player = state.players[owner]
	local recalled = from_reserve(player)
	local fleet = {
		id = state.next_fleet_id,
		owner = owner,
		name = recalled and recalled.name or M.fleet_name(player),
		number = recalled and recalled.number or (player.next_commander_number - 1),
		-- The commander half. Everything else about them - rank, what they can
		-- lead, how fast they move, what they are worth in a fight - is derived
		-- from these two numbers, so state carries nothing it can compute.
		level = recalled and recalled.level or 1,
		xp = recalled and recalled.xp or 0,
		ships = ships,
		at = at,
		progress = 0,
		route = {},
	}
	state.next_fleet_id = state.next_fleet_id + 1
	state.fleets[#state.fleets + 1] = fleet
	return fleet
end

function M.fleet_by_id(state, id)
	for i = 1, #state.fleets do
		if state.fleets[i].id == id then return state.fleets[i] end
	end
	return nil
end

--- Is this fleet sitting still?
function M.is_parked(fleet)
	return #fleet.route == 0
end

--- The system a moving fleet is heading for next, or nil if it is parked.
function M.next_hop(fleet)
	return fleet.route[1]
end

--- The player's fleets parked at `at`, lowest id first.
function M.fleets_at(state, owner, at, parked_only)
	local out = {}
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if f.owner == owner and f.at == at
			and (not parked_only or M.is_parked(f)) then
			out[#out + 1] = f
		end
	end
	table.sort(out, function(p, q) return p.id < q.id end)
	return out
end

--- Fold every co-located parked fleet of one owner into the oldest of them.
--
-- Run at the end of every turn. Without it the map silts up: fleets arrive
-- alongside each other and stay separate, and the list becomes unusable. The
-- oldest name survives, which reads as the 1st Fleet absorbing reinforcements.
--
-- The consequence is that two fleets cannot be held apart at the same system -
-- so splitting is something you do *in order to move*, which is why a move
-- order carries an optional ship count rather than there being a split verb.
function M.consolidate(state)
	-- Lowest id per (owner, system) wins, then everyone else pours into it.
	local keeper = {}
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if M.is_parked(f) then
			local key = f.owner * 1000000 + f.at
			local held = keeper[key]
			if not held or f.id < held.id then keeper[key] = f end
		end
	end
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if M.is_parked(f) then
			local held = keeper[f.owner * 1000000 + f.at]
			if held and held ~= f then
				held.ships = held.ships + f.ships
				f.ships = 0
			end
		end
	end
	M.prune_fleets(state)
end

--- Ships a player has in garrisons.
function M.garrisons_of(state, player)
	local total = 0
	for _, sys in pairs(state.systems) do
		if sys.owner == player then total = total + (sys.ships or 0) end
	end
	return total
end

--- Drop fleets that have nothing left in them.
--- Where a beaten commander falls back to: their home if they still hold it,
--- otherwise the first colony they do, otherwise anywhere at all.
---
--- Nil means the player has nothing left, and the officer goes with the empire.
function M.refuge(state, owner)
	local player = state.players[owner]
	local home = player and player.home
	if home and state.systems[home] and state.systems[home].owner == owner then
		return home
	end
	local owned = M.owned_by(state, owner)
	for i = 1, #owned do
		if (state.systems[owned[i]].population or 0) > 0 then return owned[i] end
	end
	return owned[1]
end

function M.prune_fleets(state)
	local surviving = {}
	for i = 1, #state.fleets do
		if state.fleets[i].ships >= rules.min_fleet_size then
			surviving[#surviving + 1] = state.fleets[i]
		end
	end
	state.fleets = surviving
end

-- Aggregates -------------------------------------------------------------------

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

--- Ships a player has in fleets.
function M.fleet_ships_of(state, player)
	local total = 0
	for i = 1, #state.fleets do
		if state.fleets[i].owner == player then total = total + state.fleets[i].ships end
	end
	return total
end

--- Every ship a player has, garrisoned or under way.
function M.ships_of(state, player)
	return M.garrisons_of(state, player) + M.fleet_ships_of(state, player)
end

--- Is the player still in the game? No systems and no fleets is out.
function M.is_alive(state, player)
	for _, sys in pairs(state.systems) do
		if sys.owner == player then return true end
	end
	for i = 1, #state.fleets do
		if state.fleets[i].owner == player then return true end
	end
	return false
end

-- Storage ----------------------------------------------------------------------

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
	state.next_fleet_id = tonumber(state.next_fleet_id) or 1

	for i = 1, #(state.players or {}) do
		local p = state.players[i]
		p.race = races.exists(p.race) and p.race or races.DEFAULT
		p.research = tonumber(p.research) or 0
		p.tech = tech.normalise_known(p.tech)
		p.next_fleet_number = tonumber(p.next_fleet_number) or 1
		if p.researching == "" then p.researching = nil end
		if p.researching and not tech.by_id(p.researching) then p.researching = nil end
	end

	for _, sys in pairs(state.systems or {}) do
		sys.population = tonumber(sys.population) or 0
		sys.ships = tonumber(sys.ships) or 0
		sys.buildings = buildings.normalise(sys.buildings)
		if type(sys.building) == "table" and sys.building.kind then
			sys.building = {
				kind = sys.building.kind,
				paid = tonumber(sys.building.paid) or 0,
			}
		else
			sys.building = nil
		end
	end

	for i = 1, #state.fleets do
		local f = state.fleets[i]
		f.id = tonumber(f.id) or i
		f.ships = tonumber(f.ships) or 0
		f.at = tonumber(f.at) or 1
		f.progress = tonumber(f.progress) or 0
		f.name = f.name or "Fleet"
		-- A route is a dense array and survives JSON, but an empty one can come
		-- back as an object rather than a list.
		local route = {}
		if type(f.route) == "table" then
			for k = 1, #f.route do
				local id = tonumber(f.route[k])
				if id then route[#route + 1] = id end
			end
		end
		f.route = route
	end

	return state
end

return M
