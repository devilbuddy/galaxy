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
local state_mod = require("galaxy.sim.state")
local commanders = require("galaxy.sim.commanders")
local regions_mod = require("galaxy.sim.regions")
local buildings = require("galaxy.sim.buildings")
local units = require("galaxy.sim.units")

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
			push(id, rules.base_vision + mods.vision)
		end
	end
	for i = 1, #state.captains do
		local captain = state.captains[i]
		if captain.owner == player then
			local reach = rules.captain_vision + mods.vision
			push(captain.at, reach)
			push(captain.route[1], reach)
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
			capital_of = sys.capital_of,
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

	-- What a system costs to take is derived from the star, which is public, so
	-- the client could recompute it - except for the owner's race modifier,
	-- which it has no business knowing the shape of. Sending the finished number
	-- keeps `rules.defence` from having to be re-implemented on the client and
	-- keeps the two from drifting.
	local defence_mods = {}
	for i = 1, #state.players do
		defence_mods[i] = modifiers.of(state.players[i])
	end

	-- Keyed by *string* id. A Lua table with sparse integer keys is encoded
	-- ambiguously as JSON - some encoders produce an object, others a
	-- null-padded array - and the client must be able to tell which system each
	-- entry describes. String keys always encode as an object.
	local out_systems = {}
	for id in pairs(visible) do
		local sys = state.systems[id]
		out_systems[tostring(id)] = {
			owner = sys.owner,
			capital_of = sys.capital_of,
			seen = state.turn,
			live = true,
			-- **The two halves an attacker compares against, separately.** The
			-- fleet half is filled in below, from the contacts the player can
			-- actually see - a garrison you have no eyes on is not a number you
			-- are handed.
			fortification = sys.owner ~= 0 and (systems.defence(galaxy, id,
				sys.capital_of == sys.owner, defence_mods[sys.owner])
				+ buildings.defence_bonus(sys)) or nil,
			fleet = sys.owner ~= 0 and units.power(sys.garrison, units.FLEET)
				or nil,
			-- What is standing there. Public where the system is visible: the
			-- borders show it, and an attacker who cannot see a Bastion coming
			-- is being asked to guess at the one number that decides the fight.
			buildings = sys.buildings,
			-- What a system pays its owner, and what its dwellings have ready.
			-- Both public where you can see the system: the yield is derived
			-- from the star, and what a colony makes is legible from the
			-- buildings standing on it, which are already on the wire.
			yield = systems.yield(galaxy, id,
				sys.capital_of ~= 0 and sys.capital_of == sys.owner),
			available = systems.is_colony(galaxy, id)
				and units.normalise(sys.available) or nil,
			-- **The garrison is public where the system is.** It is half of the
			-- comparison an attacker has to beat, and a fleet nobody can see is
			-- the one number this design has never asked a player to guess at.
			garrison = (sys.owner ~= 0 and units.count(sys.garrison) > 0)
				and units.normalise(sys.garrison) or nil,
		}
	end
	for id, seen in pairs(memory) do
		if not out_systems[tostring(id)] then
			out_systems[tostring(id)] = {
				owner = seen.owner,
				capital_of = seen.capital_of or 0,
				seen = seen.turn,
				live = false,
			}
		end
	end

	-- Your own captains in full; everyone else's only where you have eyes, and
	-- without their orders - you can see where someone is, not their campaign.
	local captains, contacts = {}, {}
	for i = 1, #state.captains do
		local c = state.captains[i]
		if c.owner == player then
			local profile = commanders.profile(c, mods, me.race)
			captains[#captains + 1] = {
				id = c.id, name = c.name,
				at = c.at, next_hop = c.route[1],
				route = c.route,
				-- Turns, not lanes: with a whole number of steps a turn this is
				-- literally when the captain arrives, which is what a player is
				-- actually asking when they look at it.
				eta = math.ceil(#c.route / math.max(1, profile.steps)),
				lanes = #c.route,
				level = profile.level, rank = profile.rank,
				portrait = profile.portrait,
				xp = profile.xp, next_xp = profile.next_xp,
				steps = profile.steps,
				-- The two numbers the sheet compares against a target's two
				-- halves, and the hold they were computed from.
				siege_power = profile.siege_power,
				fleet_power = profile.fleet_power,
				base_strength = profile.base_strength,
				shield = profile.shield,
				hold = profile.hold,
				carried = profile.carried,
				max_units = profile.max_units,
			}
		elseif visible[c.at] or (c.route[1] and visible[c.route[1]]) then
			-- **A rival's strength is shown, not just their rank.** Combat is a
			-- comparison the attacker is expected to do before committing, and
			-- hiding half of it would turn every attack into a guess - which is
			-- the one thing a game checked twice a day cannot afford. What stays
			-- hidden is where they are *going*: you can see a fleet, not a plan.
			local them = state.players[c.owner]
			local their_mods = modifiers.of(them)
			-- What they are worth *defending*, which is the number an attacker
			-- has to beat. Their siege power is their business.
			local their_fleet = commanders.power(c, their_mods, units.FLEET)
			local entry = out_systems[tostring(c.at)]
			if entry and entry.fleet then entry.fleet = entry.fleet + their_fleet end
			contacts[#contacts + 1] = {
				owner = c.owner, at = c.at, next_hop = c.route[1],
				rank = commanders.rank(c.level or 1),
				fleet_power = their_fleet,
				-- Their face, not their name. Portraits are grouped by race, so
				-- this is how a player learns whose fleet is on their border
				-- without being handed the officer's identity.
				portrait = commanders.portrait(c.number, nil, them.race),
			}
		end
	end

	local roster = {}
	for i = 1, #state.players do
		-- Names, race and liveness are public - you should know what you are
		-- up against - but holdings are not.
		roster[i] = {
			name = state.players[i].name,
			race = state.players[i].race,
			alive = state.players[i].alive,
			bot = state.players[i].bot and true or nil,
			capital = state.players[i].capital,
		}
	end

	-- Region control is public. Who holds what is visible from the borders on
	-- the map, and an objective nobody can see the state of is not an objective.
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
		systems = out_systems,
		captains = captains,
		contacts = contacts,
		race = me.race,
		capital = me.capital,
		regions = region_view,
		region_weights = regions_mod.weights(galaxy),
		regions_needed = regions_mod.needed(galaxy),
		-- The catalogues, so the client lists what can be built or embarked -
		-- and what each is worth against which half - without carrying a second
		-- copy of either table.
		buildings = buildings.CATALOGUE,
		units = units.CATALOGUE,
		regions_held = regions_mod.tally(galaxy, state, held)[player] or 0,
		-- The numbers the client needs to explain itself.
		-- The purse. Fungible across the map, and the one number a player has to
		-- watch between turns.
		supply = me.supply or 0,
		rates = {
			systems = state_mod.holdings_of(state, player),
			steps = commanders.steps({ level = 1 }, mods),
			hops = mods.hops,
			vision = mods.vision,
			garrison_cap = rules.garrison_cap,
			captain_cost = rules.captain_cost,
			captains = #state_mod.captains_of(state, player),
			captain_cap = buildings.captain_cap(state, player),
			building_slots = rules.building_slots,
			-- How many decisions this turn is worth, and what each kind of them
			-- costs against it. Sent rather than assumed so the client counts
			-- with the same table the server enforces.
			orders_per_turn = rules.orders_per_turn,
			order_cost = rules.order_cost,
			income = (function()
				local total = 0
				for id, sys in pairs(state.systems) do
					if sys.owner == player then
						total = total + systems.yield(galaxy, id,
							sys.capital_of == player)
					end
				end
				return total
			end)(),
		},
	}
end

return M
