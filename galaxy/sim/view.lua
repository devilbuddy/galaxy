--- Fog of war: what each player is allowed to know.
--
-- The star map itself is public - geometry, names, and because they are derived
-- from the star class and feature, what kind of place every system is and what
-- it is worth. Everyone gets that, because the map is the game's visual
-- centrepiece and because you should be able to plan a conquest around what
-- ground is *for*. What is hidden is the live state: who holds what, how
-- developed it is, and where the fleets are.
--
-- **Detection is a range, per source.** A system sees as far as its radar can
-- reach; a fleet barely sees past itself. That is what makes a developed border
-- outpost a listening post worth fighting over, and it is why enemy fleets are
-- visible at all - a conquest game where an invasion cannot be seen coming is
-- one where you lose worlds overnight with no way to answer.

local modifiers = require("galaxy.sim.modifiers")
local rules = require("galaxy.sim.rules")
local systems = require("galaxy.sim.systems")
local buildings = require("galaxy.sim.buildings")
local state_mod = require("galaxy.sim.state")
local tech = require("galaxy.sim.tech")
local commanders = require("galaxy.sim.commanders")
local regions_mod = require("galaxy.sim.regions")

local M = {}

--- Systems a player can currently observe, as id -> lanes of range to spare.
--
-- A relaxation rather than a plain breadth-first walk, because sources have
-- different reach: a radar-3 world outranges a fleet by four lanes, and the
-- widest source has to win wherever they overlap.
function M.visible_systems(galaxy, state, player, mods)
	mods = mods or modifiers.of(state.players[player])

	local best = {}
	local queue = {}

	local function push(id, budget)
		if not id or budget < 0 then return end
		local seen = best[id]
		if seen and seen >= budget then return end
		best[id] = budget
		queue[#queue + 1] = { id, budget }
	end

	for id, sys in pairs(state.systems) do
		if sys.owner == player then
			push(id, systems.vision(galaxy, id, sys.buildings, mods))
		end
	end
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if fleet.owner == player then
			local reach = rules.fleet_vision + mods.vision
			push(fleet.at, reach)
			push(fleet.route[1], reach)
		end
	end

	local head = 1
	while head <= #queue do
		local entry = queue[head]
		head = head + 1
		local id, budget = entry[1], entry[2]
		-- Skip entries superseded by a wider source before they were reached.
		if best[id] == budget and budget > 0 then
			local neighbours = galaxy.adjacency[id]
			for k = 1, #neighbours do
				push(neighbours[k], budget - 1)
			end
		end
	end

	return best
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
			population = sys.population,
			garrison = sys.ships,
			radar = sys.buildings.radar,
			fortress = sys.buildings.fortress,
			shipyard = sys.buildings.shipyard,
		}
	end
	return visible
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
	local out_systems = {}
	for id in pairs(visible) do
		local sys = state.systems[id]
		local mine = sys.owner == player
		out_systems[tostring(id)] = {
			owner = sys.owner,
			population = sys.population,
			-- The immobile force sitting on it, which is most of what defends it.
			garrison = sys.ships,
			-- Buildings are structures: if you can see the world you can see
			-- its fortress and its radar mast.
			buildings = {
				radar = sys.buildings.radar,
				fortress = sys.buildings.fortress,
				shipyard = sys.buildings.shipyard,
			},
			-- What it would defend itself with, before any fleet.
			defence = math.floor(systems.defence(galaxy, id, sys, sys.buildings)
				* (mine and mods.fortress or 1)),
			-- Only your own worlds report what they are producing and building.
			output = mine and math.floor(
				systems.output(galaxy, id, sys, mods, sys.buildings)) or nil,
			building = mine and sys.building and {
				kind = sys.building.kind,
				paid = sys.building.paid,
				cost = buildings.cost(sys.building.kind,
					sys.buildings[sys.building.kind] or 0, mods.building_cost),
			} or nil,
			capacity = systems.capacity(galaxy, id, mine and mods or nil),
			home_of = sys.home_of,
			seen = state.turn,
			live = true,
		}
	end
	for id, seen in pairs(memory) do
		if not out_systems[tostring(id)] then
			out_systems[tostring(id)] = {
				owner = seen.owner,
				population = seen.population,
				garrison = seen.garrison or 0,
				buildings = {
					radar = seen.radar or 0,
					fortress = seen.fortress or 0,
					shipyard = seen.shipyard or 0,
				},
				seen = seen.turn,
				live = false,
			}
		end
	end

	-- Your own fleets in full; everyone else's only where you have eyes, and
	-- without their orders - you can see a force in a lane, not its campaign.
	local fleets, contacts = {}, {}
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if f.owner == player then
			local profile = commanders.profile(f, mods)
			fleets[#fleets + 1] = {
				id = f.id, name = f.name, ships = f.ships,
				at = f.at, next_hop = f.route[1], progress = f.progress,
				route = f.route, eta = #f.route,
				-- The commander, flattened: the client should never have to
				-- know the level curve to draw a rank or a capacity bar.
				level = profile.level, rank = profile.rank,
				xp = profile.xp, next_xp = profile.next_xp,
				command = profile.command, speed = profile.speed,
				tactics = profile.tactics,
			}
		elseif visible[f.at] or (f.route[1] and visible[f.route[1]]) then
			-- An enemy commander's rank shows - you can tell a veteran force
			-- from a green one by how it moves - but not their experience.
			contacts[#contacts + 1] = {
				owner = f.owner, ships = f.ships,
				at = f.at, next_hop = f.route[1], progress = f.progress,
				rank = commanders.rank(f.level or 1),
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
	-- encodes as `[]` or `{}` depending on the encoder and the client would have
	-- to guess. Ordered by the tree so the list is stable.
	local known = {}
	for i = 1, #tech.TECHS do
		if me.tech[tech.TECHS[i].id] then known[#known + 1] = tech.TECHS[i].id end
	end

	local population = state_mod.population_of(state, player)

	-- Region control is public. Who holds what is visible from the borders on
	-- the map, and an objective nobody can see the state of is not an
	-- objective - a player has to be able to tell how close the game is.
	local held, counts = regions_mod.control(galaxy, state)
	local region_view = {}
	for r = 1, #held do
		region_view[r] = { held = held[r], mine = (counts[r] or {})[player] or 0 }
	end

	return {
		turn = state.turn,
		you = player,
		winner = state.winner,
		players = roster,
		regions = region_view,
		region_weights = regions_mod.weights(galaxy),
		regions_needed = regions_mod.needed(galaxy),
		regions_held = regions_mod.tally(galaxy, state, held)[player] or 0,
		commander_cap = rules.commander_cap,
		systems = out_systems,
		fleets = fleets,
		contacts = contacts,
		research = me.research,
		tech = known,
		researching = me.researching,
		available_tech = tech.available(me.tech),
		race = me.race,
		-- The numbers the client needs to explain itself.
		rates = {
			ships = state_mod.ships_of(state, player),
			garrisoned = state_mod.garrisons_of(state, player),
			ship_cap = math.floor(population * mods.cap),
			population = population,
			-- A commander's speed is their own (level x race x tech), so what
			-- the empire has is a multiplier, not a distance. Reported as the
			-- speed a green officer actually moves at, which is the number a
			-- player can compare against a lane.
			speed = commanders.speed({ level = 1 }, mods),
			speed_scale = mods.speed_scale,
			commander_cap = rules.commander_cap,
			hops = mods.hops,
			vision = mods.vision,
			tech_cost = mods.tech_cost,
			ship_cost = mods.ship_cost,
			building_cost = mods.building_cost,
		},
	}
end

return M
