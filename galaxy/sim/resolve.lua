--- Turn resolution.
--
-- `resolve.turn(galaxy, state, orders)` advances the game by exactly one turn
-- and returns the events it produced. It is a pure function of its inputs plus
-- the seeded RNG, so a turn can be replayed and a whole game reconstructed from
-- (seed, orders history). That is what makes it testable at LuaJIT speed
-- offline while running on Nakama's much slower interpreter in production.
--
-- Order within a turn:
--   0. directives   - standing choices (research target, build policy) apply
--                     before anything spends, so a change takes effect at once
--   1. growth       - population moves towards capacity
--   2. income       - systems and trade routes pay into the stockpile
--   3. upkeep       - the fuel bill; unfuelled warships are lost
--   4. research     - buy the chosen technology if it is now affordable
--   5. build        - lay down warships and freighters
--   6. departures   - orders become fleets, ships leave their systems
--   7. movement     - fleets advance along lanes, stopping at hostile systems
--   8. battles      - everything that met this turn fights
--   9. arrivals     - surviving freighters open or reinforce trade routes
--  10. aftermath    - eliminations, then each player's fog of war is updated
--
-- Stockpiles are integers. Rates are not: income, upkeep and unit costs are all
-- fractional once races and technology scale them, so each is summed as a float
-- and rounded exactly once, per player per turn. Keeping the *stored* numbers
-- integral is what lets state survive a JSON round-trip through Nakama storage
-- without the replay drifting from the original.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local state_mod = require("galaxy.sim.state")
local path_mod = require("galaxy.sim.path")
local view = require("galaxy.sim.view")
local resources = require("galaxy.sim.resources")
local modifiers = require("galaxy.sim.modifiers")
local tech_mod = require("galaxy.sim.tech")

local M = {}

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local function emit(events, e)
	events[#events + 1] = e
	return e
end

--- Remove `count` warships from a player, systems first and weakest last.
--
-- Sorted by system id so the choice never depends on table iteration order,
-- and fleets in transit are raided only once every garrison is empty: losing a
-- fleet mid-flight to an accounting rule reads as a bug to the player.
local function strip_warships(state, player, count)
	if count <= 0 then return 0 end
	local removed = 0
	local owned = state_mod.owned_by(state, player)
	for i = 1, #owned do
		if removed >= count then break end
		local sys = state.systems[owned[i]]
		local take = min(sys.ships, count - removed)
		sys.ships = sys.ships - take
		removed = removed + take
	end
	for i = 1, #state.fleets do
		if removed >= count then break end
		local f = state.fleets[i]
		if f.owner == player and f.kind ~= "trade" then
			local take = min(f.ships, count - removed)
			f.ships = f.ships - take
			removed = removed + take
		end
	end
	-- A fleet stripped to nothing must not linger as a zero-strength ghost that
	-- still blockades a lane.
	local surviving = {}
	for i = 1, #state.fleets do
		if state.fleets[i].ships > 0 then surviving[#surviving + 1] = state.fleets[i] end
	end
	state.fleets = surviving
	return removed
end

-- 0. Directives ---------------------------------------------------------------

--- Apply the standing choices in this turn's orders.
--
-- These are not actions; they are settings. Applying them first means a player
-- who switches research target and submits in the same turn gets the new
-- target funded this turn rather than next.
local function directives(state, orders, events)
	for i = 1, #orders do
		local order = orders[i]
		local player = state.players[order.player]
		if player then
			if order.kind == "research" then
				local id = order.tech
				if id == nil or id == "" then
					player.researching = nil
				else
					local ok, why = tech_mod.can_research(player.tech, id)
					if ok then
						player.researching = id
					else
						emit(events, {
							kind = "order_rejected", turn = state.turn,
							player = order.player, tech = id, reason = why,
							visible_to = { order.player },
						})
					end
				end
			elseif order.kind == "policy" then
				local share = tonumber(order.warship_share)
				if share then
					if share < 0 then share = 0 end
					if share > 1 then share = 1 end
					player.warship_share = share
				end
			end
		end
	end
end

-- 1. Growth --------------------------------------------------------------------

local function growth(galaxy, state, mods, summaries)
	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner ~= 0 then
			local m = mods[sys.owner]
			local capacity = state_mod.capacity(galaxy, id, m)
			-- Growth on remaining headroom, so an empty colony fills quickly and
			-- a full one stagnates. This also lets a freshly claimed system with
			-- zero population get started without a special case.
			local headroom = capacity - sys.population
			if headroom > 0 then
				-- At least one per turn: floor(headroom * rate) reaches zero once
				-- headroom drops below 1/rate, which left every system stalled a
				-- few percent short of capacity forever.
				local grown = max(1, floor(headroom * m.growth))
				sys.population = min(capacity, sys.population + grown)
			elseif headroom < 0 then
				-- Capacity can fall - a captured world loses the previous
				-- owner's terraforming - so the excess has to drain somewhere.
				sys.population = capacity
			end

			local s = summaries[sys.owner]
			if s then
				s.population = s.population + sys.population
				s.systems = s.systems + 1
			end
		end
	end
end

-- 2. Income ---------------------------------------------------------------------

--- What one route pays this turn, before it is split between the two resources.
local function route_value(state, route, m)
	local a, b = state.systems[route.a], state.systems[route.b]
	local length_factor = min(rules.trade_length_cap, route.length / rules.trade_length_reference)
	local pop_factor = min(rules.trade_pop_cap,
		(a.population + b.population) / rules.trade_pop_reference)
	return route.ships * m.trade * length_factor * pop_factor
end

local function income(galaxy, state, mods, events, summaries)
	local gross = {}
	for i = 1, #state.players do gross[i] = resources.zero() end

	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner ~= 0 then
			local base = resources.base_yield(galaxy, id)
			-- The flat term is what makes a newly taken world worth something
			-- before it has filled; the per-head term is what makes holding it
			-- long-term worth more.
			local scale = rules.yield_flat + sys.population * rules.yield_per_pop
			local m = mods[sys.owner]
			local g = gross[sys.owner]
			g.metal = g.metal + base.metal * scale * m.yield_metal
			g.fuel = g.fuel + base.fuel * scale * m.yield_fuel
			g.research = g.research + base.research * scale * m.yield_research
		end
	end

	-- Trade routes pay in research and fuel, never metal. Hulls always have to
	-- come out of ground you hold, so a commercial empire still needs one.
	local surviving = {}
	for i = 1, #state.routes do
		local route = state.routes[i]
		local a, b = state.systems[route.a], state.systems[route.b]
		local intact = a and b and a.owner == route.owner and b.owner == route.owner
		if intact and route.ships > 0 then
			local value = route_value(state, route, mods[route.owner])
			local g = gross[route.owner]
			if g then
				g.research = g.research + value * 0.5
				g.fuel = g.fuel + value * 0.5
			end
			local s = summaries[route.owner]
			if s then s.trade = s.trade + value end
			surviving[#surviving + 1] = route
		elseif route.ships > 0 then
			-- One end has changed hands. The freighters make for whichever end
			-- is still friendly and dock there; if neither is, they are gone.
			local refuge = nil
			if a and a.owner == route.owner then refuge = route.a
			elseif b and b.owner == route.owner then refuge = route.b end
			if refuge then
				state.systems[refuge].freighters = state.systems[refuge].freighters + route.ships
			end
			emit(events, {
				kind = "route_lost", turn = state.turn, player = route.owner,
				a = route.a, b = route.b, ships = route.ships,
				recovered = refuge ~= nil,
				visible_to = { route.owner },
			})
		end
	end
	state.routes = surviving

	for i = 1, #state.players do
		local stock = state.players[i].stock
		local g = gross[i]
		local earned = {
			metal = floor(g.metal), fuel = floor(g.fuel), research = floor(g.research),
		}
		resources.add(stock, earned)
		local s = summaries[i]
		if s then s.income = earned end
	end
end

-- 3. Upkeep -----------------------------------------------------------------------

--- Charge the fuel bill, and take the difference out of the fleet.
--
-- This is the live ceiling on fleet size. The population cap in rules.lua is a
-- backstop that only binds if the fuel economy somehow does not.
local function upkeep(state, mods, events, summaries, starved)
	for i = 1, #state.players do
		local player = state.players[i]
		local m = mods[i]
		local warships = state_mod.warships_of(state, i)
		if warships > 0 and m.upkeep > 0 then
			local bill = ceil(warships * m.upkeep)
			local paid = min(player.stock.fuel, bill)
			player.stock.fuel = player.stock.fuel - paid

			local s = summaries[i]
			if s then s.fuel_spent = s.fuel_spent + paid end

			if paid < bill then
				starved[i] = true
				-- Ships the tanks could not reach. They are not all lost at
				-- once: a fuel crisis should be a slide the player can arrest,
				-- not a fleet that evaporates in a turn.
				local unfuelled = ceil((bill - paid) / m.upkeep)
				local lost = max(1, floor(unfuelled * rules.unfuelled_attrition))
				lost = strip_warships(state, i, min(lost, warships))
				if lost > 0 then
					emit(events, {
						kind = "attrition", turn = state.turn, player = i,
						ships = lost, reason = "fuel",
						visible_to = { i },
					})
					if s then s.attrition = s.attrition + lost end
				end
			end
		end
	end
end

-- 4. Research ----------------------------------------------------------------------

--- Buy the chosen technology if the stockpile now covers it.
--
-- Returns true when anything completed, so the caller can rebuild that
-- player's modifiers before the rest of the turn reads them.
local function research(state, mods, events, summaries)
	local changed = false
	for i = 1, #state.players do
		local player = state.players[i]
		local target = player.researching
		if target then
			local ok = tech_mod.can_research(player.tech, target)
			if not ok then
				player.researching = nil
			else
				local cost = tech_mod.cost_of(target, mods[i].tech_cost)
				if resources.can_pay(player.stock, cost) then
					resources.pay(player.stock, cost)
					player.tech[target] = true
					player.researching = nil
					changed = true
					mods[i] = modifiers.of(player)
					emit(events, {
						kind = "research_complete", turn = state.turn,
						player = i, tech = target,
						visible_to = { i },
					})
					local s = summaries[i]
					if s then s.researched = target end
				end
			end
		end
	end
	return changed
end

-- 5. Build ------------------------------------------------------------------------

local function build(galaxy, state, mods, events, summaries, starved)
	for i = 1, #state.players do
		local player = state.players[i]
		local m = mods[i]
		local stock = player.stock
		local pop = state_mod.population_of(state, i)
		local warships = state_mod.warships_of(state, i)
		local supported = floor(pop * m.cap)

		-- Over the population backstop: shed the excess before building more.
		if warships > supported then
			local excess = floor((warships - supported) * rules.over_cap_attrition)
			if excess > 0 then
				local shed = strip_warships(state, i, excess)
				warships = warships - shed
				local s = summaries[i]
				if s then s.scrapped = shed end
			end
		end

		local room = max(0, supported - warships)
		-- The yards stop while the tanks are dry. Without this the metal income
		-- of a fuel-starved empire is spent entirely on replacing ships that
		-- attrition removes the same turn - a treadmill that reads as the
		-- economy being broken rather than as a fleet being too big.
		if starved[i] then room = 0 end
		local war_metal = rules.warship_cost.metal * m.ship_cost
		local war_fuel = rules.warship_cost.fuel * m.ship_cost
		local frt_metal = rules.freighter_cost.metal * m.ship_cost

		local owned = state_mod.owned_by(state, i)
		for k = 1, #owned do
			local id = owned[k]
			local sys = state.systems[id]
			local rate = m.industry
			if sys.home_of == i then rate = rate * rules.home_production_bonus end
			local capacity = floor(sys.population * rate)
			if capacity > 0 then
				-- Rounded to nearest so a share of 1.0 never leaks a freighter
				-- and a share of 0.0 never leaks a warship.
				local want_war = floor(capacity * player.warship_share + 0.5)
				local want_frt = capacity - want_war

				if want_war > 0 and room > 0 then
					local n = min(want_war, room)
					if war_metal > 0 then n = min(n, floor(stock.metal / war_metal)) end
					if war_fuel > 0 then n = min(n, floor(stock.fuel / war_fuel)) end
					if n > 0 then
						-- Charged with floor, so rounding can only ever favour
						-- the player by less than one unit per system per turn.
						stock.metal = stock.metal - floor(n * war_metal)
						stock.fuel = stock.fuel - floor(n * war_fuel)
						sys.ships = sys.ships + n
						room = room - n
						local s = summaries[i]
						if s then
							s.built = s.built + n
							s.metal_spent = s.metal_spent + floor(n * war_metal)
							s.fuel_spent = s.fuel_spent + floor(n * war_fuel)
						end
					end
				end

				if want_frt > 0 and frt_metal > 0 then
					local n = min(want_frt, floor(stock.metal / frt_metal))
					if n > 0 then
						stock.metal = stock.metal - floor(n * frt_metal)
						sys.freighters = sys.freighters + n
						local s = summaries[i]
						if s then
							s.freighters_built = s.freighters_built + n
							s.metal_spent = s.metal_spent + floor(n * frt_metal)
						end
					end
				end
			end
		end
	end
end

-- 6. Departures --------------------------------------------------------------

--- Turn this turn's movement orders into fleets. Invalid orders are dropped
--- with a reason rather than silently ignored, so a client can show why.
local function departures(galaxy, state, orders, mods, lengths, events)
	for i = 1, #orders do
		local order = orders[i]
		local kind = order.kind
		if kind == nil or kind == "move" or kind == "trade" then
			local trading = (kind == "trade")
			local player = order.player
			local from, to = order.from, order.to
			local sys = state.systems[from]
			local m = mods[player]

			local reason = nil
			if not m then
				reason = "no such player"
			elseif not sys then
				reason = "no such system"
			elseif sys.owner ~= player then
				reason = "you do not own the origin"
			elseif not state.systems[to] then
				reason = "no such destination"
			elseif from == to then
				reason = "origin and destination are the same"
			elseif trading and state.systems[to].owner ~= player then
				reason = "a trade route needs two systems you own"
			end

			local available = 0
			if sys then available = trading and sys.freighters or sys.ships end
			local ships = order.ships and floor(order.ships) or 0
			if not reason then
				-- Clamp rather than reject: the player ordered against the state
				-- they last saw, which may be a turn out of date.
				ships = min(ships, available)
				if ships < 1 then
					reason = trading and "no freighters available" or "no ships available"
				end
			end

			local route = nil
			if not reason then
				route = path_mod.find(galaxy, lengths, from, to, m.hops)
				if not route or #route == 0 then reason = "no route" end
			end

			if reason then
				emit(events, {
					kind = "order_rejected", turn = state.turn,
					player = player, from = from, to = to, reason = reason,
					visible_to = { player },
				})
			else
				if trading then sys.freighters = sys.freighters - ships
				else sys.ships = sys.ships - ships end

				-- Measured now, along the route actually taken, because it is
				-- what the trade route will be paid on and the lane graph the
				-- fleet used is the honest answer.
				local distance, at = 0, from
				for h = 1, #route do
					distance = distance + (path_mod.lane_length(lengths, at, route[h]) or 0)
					at = route[h]
				end

				state.fleets[#state.fleets + 1] = {
					id = state.next_fleet_id,
					owner = player,
					kind = trading and "trade" or "move",
					ships = ships,
					at = from,
					origin = from,
					path = route,
					destination = to,
					distance = distance,
					progress = 0,
				}
				state.next_fleet_id = state.next_fleet_id + 1
			end
		end
	end
end

-- 7. Movement ----------------------------------------------------------------

--- Advance every fleet, and record who ends the turn where.
--
-- A fleet stops the moment it reaches a system held by someone else: lanes can
-- be blockaded, and you cannot slip a fleet past a defended border.
local function movement(galaxy, state, mods, lengths, arrivals, docking)
	local surviving = {}

	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		local trading = fleet.kind == "trade"
		local speed = mods[fleet.owner].speed
		if trading then speed = speed * rules.freighter_speed_factor end
		local budget = speed
		local blocked = false

		while budget > 0 and #fleet.path > 0 and not blocked do
			local next_id = fleet.path[1]
			local leg = path_mod.lane_length(lengths, fleet.at, next_id) or 0
			local remaining = leg - fleet.progress

			if budget >= remaining then
				budget = budget - remaining
				fleet.at = next_id
				fleet.progress = 0
				table.remove(fleet.path, 1)

				local sys = state.systems[next_id]
				local hostile = sys.owner ~= 0 and sys.owner ~= fleet.owner
				if hostile or #fleet.path == 0 then
					blocked = true
				end
			else
				fleet.progress = fleet.progress + budget
				budget = 0
			end
		end

		if #fleet.path == 0 or blocked then
			if trading then
				-- Freighters take no part in a battle; they are sorted out
				-- after one, when it is settled who holds the system.
				docking[#docking + 1] = fleet
			else
				-- The fleet is sitting at a system this turn; group it with
				-- anyone else who turned up, so a system resolves once.
				local at = arrivals[fleet.at]
				if not at then
					at = { order = {}, by_player = {} }
					arrivals[fleet.at] = at
				end
				if not at.by_player[fleet.owner] then
					at.by_player[fleet.owner] = 0
					at.order[#at.order + 1] = fleet.owner
				end
				at.by_player[fleet.owner] = at.by_player[fleet.owner] + fleet.ships
			end
		else
			surviving[#surviving + 1] = fleet
		end
	end

	state.fleets = surviving
end

-- 8. Battles -----------------------------------------------------------------

--- One engagement. Returns whether the attacker won, and the winner's survivors.
--
-- A Lanchester-style exchange: the loser is destroyed and the winner keeps the
-- fraction of its force that the margin of victory implies, so a narrow win is
-- expensive and an overwhelming one is nearly free. The multipliers carry the
-- attacker's and defender's race and technology, including the defender's
-- inherent advantage.
local function engage(r, att_ships, att_mult, def_ships, def_mult)
	local variance = rules.combat_variance
	local a = att_ships * att_mult * r:range(1 - variance, 1 + variance)
	local d = def_ships * def_mult * r:range(1 - variance, 1 + variance)
	if d <= 0 then return true, att_ships end
	if a <= 0 then return false, def_ships end
	if a > d then
		return true, max(1, floor(att_ships * (1 - d / a)))
	end
	return false, max(1, floor(def_ships * (1 - a / d)))
end

local function battles(galaxy, state, mods, arrivals, r, events, summaries)
	-- Sorted so resolution order never depends on table iteration order.
	local ids = {}
	for id in pairs(arrivals) do ids[#ids + 1] = id end
	table.sort(ids)

	for k = 1, #ids do
		local id = ids[k]
		local incoming = arrivals[id]
		local sys = state.systems[id]
		table.sort(incoming.order)

		for oi = 1, #incoming.order do
			local player = incoming.order[oi]
			local ships = incoming.by_player[player]

			if sys.owner == player then
				-- Reinforcement.
				sys.ships = sys.ships + ships
				emit(events, {
					kind = "reinforced", turn = state.turn,
					at = id, player = player, ships = ships,
				})
			elseif sys.owner == 0 then
				-- Unclaimed: taking it is free, and it starts growing next turn.
				sys.owner = player
				sys.ships = ships
				emit(events, {
					kind = "claimed", turn = state.turn,
					at = id, player = player, ships = ships,
				})
			else
				local defender = sys.owner
				local defender_ships = sys.ships
				local won, survivors = engage(r,
					ships, mods[player].attack,
					defender_ships, mods[defender].defence)

				local spoils = 0
				if won then spoils = floor(sys.freighters * rules.freighter_capture_rate) end

				emit(events, {
					kind = "battle", turn = state.turn, at = id,
					attacker = player, defender = defender,
					attacker_ships = ships, defender_ships = defender_ships,
					winner = won and player or defender,
					survivors = survivors,
					captured = won,
					freighters_taken = spoils,
				})

				if won then
					sys.owner = player
					sys.ships = survivors
					sys.population = floor(sys.population * mods[player].capture_keep)
					-- The losing side's civilian hulls are mostly scuttled; the
					-- rest change flag.
					sys.freighters = spoils
					-- A captured home system stops being anyone's home.
					if sys.home_of ~= 0 and sys.home_of ~= player then sys.home_of = 0 end
					local s = summaries[player]
					if s then s.captured = s.captured + 1 end
					local d = summaries[defender]
					if d then d.lost = d.lost + 1 end
				else
					sys.ships = survivors
				end
			end
		end
	end
end

-- 9. Freighter arrivals -------------------------------------------------------

--- Settle every freighter fleet that stopped this turn.
--
-- Run after the battles so the answer to "is the destination still mine?" is
-- the one the turn actually ended with.
local function dock(state, docking, events, summaries)
	for i = 1, #docking do
		local fleet = docking[i]
		local sys = state.systems[fleet.at]
		local owner = fleet.owner

		if not sys or (sys.owner ~= 0 and sys.owner ~= owner) then
			-- Flew into somebody else's system, or into one that fell while
			-- they were in transit.
			local taken = 0
			if sys and sys.owner ~= 0 then
				taken = floor(fleet.ships * rules.freighter_capture_rate)
				sys.freighters = sys.freighters + taken
			end
			emit(events, {
				kind = "trade_lost", turn = state.turn, player = owner,
				at = fleet.at, ships = fleet.ships, seized_by = sys and sys.owner or 0,
				visible_to = (sys and sys.owner ~= 0) and { owner, sys.owner } or { owner },
			})
		elseif fleet.at == fleet.destination
			and state.systems[fleet.origin]
			and state.systems[fleet.origin].owner == owner
			and fleet.origin ~= fleet.at then
			-- Both ends still held: open the route, or reinforce it if these
			-- two systems are already trading.
			local existing = nil
			for k = 1, #state.routes do
				local route = state.routes[k]
				if route.owner == owner
					and ((route.a == fleet.origin and route.b == fleet.at)
						or (route.a == fleet.at and route.b == fleet.origin)) then
					existing = route
					break
				end
			end
			if existing then
				existing.ships = existing.ships + fleet.ships
				-- Keep the shorter measured distance; both fleets flew a real
				-- route and the cheaper one is the one commerce would use.
				if fleet.distance < existing.length then existing.length = fleet.distance end
			else
				state.routes[#state.routes + 1] = {
					owner = owner,
					a = fleet.origin,
					b = fleet.at,
					ships = fleet.ships,
					length = fleet.distance,
				}
			end
			emit(events, {
				kind = "route_established", turn = state.turn, player = owner,
				a = fleet.origin, b = fleet.at, ships = fleet.ships,
				visible_to = { owner },
			})
			local s = summaries[owner]
			if s then s.routes_opened = s.routes_opened + 1 end
		else
			-- Stopped short, or the far end is no longer worth trading with.
			-- They dock where they are and can be re-tasked next turn.
			sys.freighters = sys.freighters + fleet.ships
		end
	end
end

-- 10. Aftermath ---------------------------------------------------------------

local function aftermath(galaxy, state, mods, events, summaries)
	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			emit(events, { kind = "eliminated", turn = state.turn, player = i })
		end
	end

	for i = 1, #state.players do
		view.remember(galaxy, state, i)
	end

	-- A private end-of-turn digest per player: the backbone of "what happened
	-- while you were away".
	for i = 1, #state.players do
		local s = summaries[i]
		if s then
			local player = state.players[i]
			local ships, freighters = 0, 0
			for _, sys in pairs(state.systems) do
				if sys.owner == i then
					ships = ships + sys.ships
					freighters = freighters + sys.freighters
				end
			end
			for f = 1, #state.fleets do
				local fleet = state.fleets[f]
				if fleet.owner == i then
					if fleet.kind == "trade" then freighters = freighters + fleet.ships
					else ships = ships + fleet.ships end
				end
			end
			for k = 1, #state.routes do
				if state.routes[k].owner == i then freighters = freighters + state.routes[k].ships end
			end

			s.kind = "turn_summary"
			s.turn = state.turn
			s.player = i
			s.ships = ships
			s.freighters = freighters
			s.trade = floor(s.trade)
			s.stock = {
				metal = player.stock.metal,
				fuel = player.stock.fuel,
				research = player.stock.research,
			}
			s.researching = player.researching
			s.visible_to = { i }
			emit(events, s)
		end
	end
end

--- Decide who may see each event.
--
-- Participants always do. Everyone else only if the system it happened at is
-- visible to them at the end of the turn - so a battle on the far side of the
-- map is not broadcast.
local function apply_visibility(galaxy, state, events)
	local visible = {}
	for i = 1, #state.players do
		visible[i] = view.visible_systems(galaxy, state, i)
	end

	for e = 1, #events do
		local event = events[e]
		if not event.visible_to then
			local who = {}
			for i = 1, #state.players do
				local participant = (event.player == i) or (event.attacker == i) or (event.defender == i)
				if participant or (event.at and visible[i][event.at]) then
					who[#who + 1] = i
				end
			end
			-- An elimination is public; it changes the shape of the whole game.
			if event.kind == "eliminated" then
				who = {}
				for i = 1, #state.players do who[#who + 1] = i end
			end
			event.visible_to = who
		end
	end
end

--- Advance the game by one turn.
-- @return events produced this turn
function M.turn(galaxy, state, orders, lengths)
	lengths = lengths or path_mod.lane_lengths(galaxy)
	orders = orders or {}

	state.turn = state.turn + 1
	-- Seeded per turn, so replaying a turn gives identical battles.
	local r = rng.stream(state.seed, "turn:" .. state.turn)

	local events = {}
	local summaries = {}
	local mods = {}
	for i = 1, #state.players do
		summaries[i] = {
			built = 0, freighters_built = 0, scrapped = 0, attrition = 0,
			captured = 0, lost = 0, systems = 0, population = 0,
			trade = 0, routes_opened = 0,
			metal_spent = 0, fuel_spent = 0,
			income = resources.zero(),
		}
		mods[i] = modifiers.of(state.players[i])
	end

	local starved = {}

	directives(state, orders, events)
	growth(galaxy, state, mods, summaries)
	income(galaxy, state, mods, events, summaries)
	upkeep(state, mods, events, summaries, starved)
	research(state, mods, events, summaries)
	build(galaxy, state, mods, events, summaries, starved)
	departures(galaxy, state, orders, mods, lengths, events)

	local arrivals, docking = {}, {}
	movement(galaxy, state, mods, lengths, arrivals, docking)
	battles(galaxy, state, mods, arrivals, r, events, summaries)
	dock(state, docking, events, summaries)
	aftermath(galaxy, state, mods, events, summaries)
	apply_visibility(galaxy, state, events)

	return events
end

return M
