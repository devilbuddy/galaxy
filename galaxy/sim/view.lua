--- Fog of war: what each player is allowed to know.
--
-- The star map itself is public - geometry, names, lanes and, because they are
-- derived from the star class and feature, resource yields. Everyone gets it,
-- because the map is the game's visual centrepiece and hiding it would leave a
-- new player staring at emptiness, and because you should be able to plan a
-- conquest around what a system is worth. What is hidden is the *state*: who
-- owns what, who has ships where, and how strong they are.

local modifiers = require("galaxy.sim.modifiers")
local resources = require("galaxy.sim.resources")
local rules = require("galaxy.sim.rules")
local state_mod = require("galaxy.sim.state")
local tech = require("galaxy.sim.tech")

local M = {}

--- Systems a player can currently observe.
--
-- Owned systems, everything within their vision radius in lanes, and wherever
-- the player has a fleet. One lane of vision means a border system is genuinely
-- a lookout post and losing it blinds you; the Survey Network technology buys a
-- second lane, which is the difference between seeing a build-up and seeing it
-- arrive.
function M.visible_systems(galaxy, state, player, mods)
	mods = mods or modifiers.of(state.players[player])
	local radius = mods.vision
	if radius < 0 then radius = 0 end

	-- Breadth-first out from every source at once, so a system is expanded at
	-- its true minimum hop count and never re-expanded.
	local visible = {}
	local frontier = {}

	local function seed(id)
		if id and not visible[id] then
			visible[id] = true
			frontier[#frontier + 1] = id
		end
	end

	for id, sys in pairs(state.systems) do
		if sys.owner == player then seed(id) end
	end
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if fleet.owner == player then
			seed(fleet.at)
			seed(fleet.path[1])
		end
	end
	-- A trade route is a standing presence on both of its endpoints, which the
	-- owner holds anyway - but seeding them keeps the rule "you see what you
	-- have something at" true without a special case.
	for i = 1, #(state.routes or {}) do
		local route = state.routes[i]
		if route.owner == player then
			seed(route.a)
			seed(route.b)
		end
	end

	for _ = 1, radius do
		local next_frontier = {}
		for i = 1, #frontier do
			local neighbours = galaxy.adjacency[frontier[i]]
			for k = 1, #neighbours do
				local id = neighbours[k]
				if not visible[id] then
					visible[id] = true
					next_frontier[#next_frontier + 1] = id
				end
			end
		end
		frontier = next_frontier
	end

	return visible
end

--- Fold what a player can see right now into their persistent memory.
--
-- Without this the map would flicker: a system seen last turn would revert to
-- unknown the moment a scout moved on. Remembered entries are stamped with the
-- turn so the client can show them as stale.
function M.remember(galaxy, state, player)
	local visible = M.visible_systems(galaxy, state, player)
	local memory = state.knowledge[player]
	if not memory then
		memory = {}
		state.knowledge[player] = memory
	end
	for id in pairs(visible) do
		local sys = state.systems[id]
		memory[id] = {
			turn = state.turn,
			owner = sys.owner,
			ships = sys.ships,
			population = sys.population,
		}
	end
	return visible
end

--- What one player's own empire is earning, so the client can show a rate
--- rather than only a balance. Recomputed rather than stored: it is a pure
--- function of the state and storing it would be one more thing to migrate.
local function income_estimate(galaxy, state, player, mods)
	local out = resources.zero()
	for id, sys in pairs(state.systems) do
		if sys.owner == player then
			local base = resources.base_yield(galaxy, id)
			local scale = rules.yield_flat + sys.population * rules.yield_per_pop
			out.metal = out.metal + base.metal * scale * mods.yield_metal
			out.fuel = out.fuel + base.fuel * scale * mods.yield_fuel
			out.research = out.research + base.research * scale * mods.yield_research
		end
	end
	local math_min, math_floor = math.min, math.floor
	for i = 1, #(state.routes or {}) do
		local route = state.routes[i]
		local a, b = state.systems[route.a], state.systems[route.b]
		if route.owner == player and a and b and a.owner == player and b.owner == player then
			local lf = math_min(rules.trade_length_cap, route.length / rules.trade_length_reference)
			local pf = math_min(rules.trade_pop_cap,
				(a.population + b.population) / rules.trade_pop_reference)
			local value = route.ships * mods.trade * lf * pf
			out.research = out.research + value * 0.5
			out.fuel = out.fuel + value * 0.5
		end
	end
	return {
		metal = math_floor(out.metal),
		fuel = math_floor(out.fuel),
		research = math_floor(out.research),
	}
end

--- The state as one player is allowed to receive it.
--
-- Currently visible systems report live values; remembered ones report what was
-- last seen, flagged with the turn. Everything else is omitted entirely rather
-- than sent as zeroes, so the payload cannot leak strength by its shape.
function M.project(galaxy, state, player)
	local me = state.players[player]
	local mods = modifiers.of(me)
	local visible = M.visible_systems(galaxy, state, player, mods)
	local memory = state.knowledge[player] or {}

	-- Keyed by *string* id. A Lua table with sparse integer keys is encoded
	-- ambiguously as JSON - some encoders produce an object, others a
	-- null-padded array - and the client must be able to tell which system each
	-- entry describes. String keys always encode as an object.
	local systems = {}
	for id in pairs(visible) do
		local sys = state.systems[id]
		systems[tostring(id)] = {
			owner = sys.owner,
			population = sys.population,
			ships = sys.ships,
			-- Freighters are only ever reported for systems the player holds:
			-- an enemy's civilian hulls are not something a border scout counts.
			freighters = sys.owner == player and sys.freighters or nil,
			home_of = sys.home_of,
			-- The observer's own worlds report the ceiling their technology
			-- gives them; someone else's report what the star alone supports,
			-- because their terraforming is not something you can see.
			capacity = state_mod.capacity(galaxy, id, sys.owner == player and mods or nil),
			seen = state.turn,
			live = true,
		}
	end
	for id, seen in pairs(memory) do
		if not systems[tostring(id)] then
			systems[tostring(id)] = {
				owner = seen.owner,
				population = seen.population,
				ships = seen.ships,
				seen = seen.turn,
				live = false,
			}
		end
	end

	-- Only the player's own fleets. Enemy fleets in transit are invisible;
	-- you learn about them when they arrive.
	local fleets = {}
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if f.owner == player then
			fleets[#fleets + 1] = {
				id = f.id, ships = f.ships, at = f.at,
				kind = f.kind or "move",
				destination = f.destination,
				next_hop = f.path[1],
				eta = #f.path,
			}
		end
	end

	local routes = {}
	for i = 1, #(state.routes or {}) do
		local route = state.routes[i]
		if route.owner == player then
			routes[#routes + 1] = {
				a = route.a, b = route.b, ships = route.ships,
				length = route.length,
			}
		end
	end

	local roster = {}
	for i = 1, #state.players do
		-- Names, race and liveness are public - you should know what you are
		-- fighting - but holdings are not.
		roster[i] = {
			name = state.players[i].name,
			race = state.players[i].race,
			alive = state.players[i].alive,
		}
	end

	-- Researched technologies go out as an array, not a set: an empty set
	-- encodes as `[]` or `{}` depending on the encoder and the client would
	-- have to guess. Ordered by the tree so the list is stable.
	local known = {}
	for i = 1, #tech.TECHS do
		if me.tech[tech.TECHS[i].id] then known[#known + 1] = tech.TECHS[i].id end
	end

	return {
		turn = state.turn,
		you = player,
		players = roster,
		systems = systems,
		fleets = fleets,
		routes = routes,
		stock = {
			metal = me.stock.metal, fuel = me.stock.fuel, research = me.stock.research,
		},
		income = income_estimate(galaxy, state, player, mods),
		tech = known,
		researching = me.researching,
		available_tech = tech.available(me.tech),
		warship_share = me.warship_share,
		race = me.race,
		-- The numbers the client needs to explain itself: what a ship costs,
		-- what the fleet bill is, how far an order may reach.
		rates = {
			upkeep = mods.upkeep,
			speed = mods.speed,
			hops = mods.hops,
			vision = mods.vision,
			tech_cost = mods.tech_cost,
			ship_cost = mods.ship_cost,
		},
	}
end

return M
