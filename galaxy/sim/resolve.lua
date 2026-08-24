--- Turn resolution.
--
-- `resolve.turn(galaxy, state, orders)` advances the game by exactly one turn
-- and returns the events it produced. It is a pure function of its inputs plus
-- the seeded RNG, so a turn can be replayed and a whole game reconstructed from
-- (seed, orders history). That is what makes it testable at LuaJIT speed offline
-- while running on Nakama's much slower interpreter in production.
--
-- Order within a turn:
--   1. directives    - standing choices: research target, what to build where
--   2. growth        - colony populations move towards capacity
--   3. industry      - output becomes a building or ships; research pools
--   4. research      - buy the chosen technology if it is now affordable
--   5. fleet orders  - split, merge, and set routes
--   6. movement      - fleets advance along their routes
--   7. interception  - hostile fleets that met in a lane
--   8. battles       - everything that met at a system
--   9. aftermath     - eliminations, then each player's fog of war
--
-- Numbers stored in state are integers. Output and research are fractional once
-- races, technology and star class have scaled them, so each is summed as a
-- float and floored exactly once, per system per turn. Keeping the *stored*
-- values integral is what lets state survive a JSON round-trip through Nakama
-- storage without a replay drifting from the original.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local commanders = require("galaxy.sim.commanders")
local regions_mod = require("galaxy.sim.regions")
local state_mod = require("galaxy.sim.state")
local path_mod = require("galaxy.sim.path")
local view = require("galaxy.sim.view")
local systems = require("galaxy.sim.systems")
local buildings = require("galaxy.sim.buildings")
local modifiers = require("galaxy.sim.modifiers")
local tech_mod = require("galaxy.sim.tech")

local M = {}

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local function emit(events, e)
	events[#events + 1] = e
	return e
end

--- A beaten commander is scattered, not killed.
--
-- Losing an officer outright would make one bad battle unrecoverable in a game
-- checked twice a day, and would teach players never to commit. They fall back
-- to a world they still hold, one rank lighter. Only a player with nowhere left
-- to fall back to actually loses them.
local function scatter(state, events)
	local surviving = {}
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if fleet.ships >= rules.min_fleet_size then
			surviving[#surviving + 1] = fleet
		else
			local refuge = state_mod.refuge(state, fleet.owner)
			if refuge then
				local level = commanders.demote(fleet)
				fleet.at = refuge
				fleet.progress = 0
				fleet.route = {}
				fleet.ships = 0
				surviving[#surviving + 1] = fleet
				emit(events, {
					kind = "commander_scattered", turn = state.turn,
					player = fleet.owner, fleet = fleet.id, name = fleet.name,
					at = refuge, level = level, rank = commanders.rank(level),
					visible_to = { fleet.owner },
				})
			else
				emit(events, {
					kind = "commander_lost", turn = state.turn,
					player = fleet.owner, fleet = fleet.id, name = fleet.name,
					visible_to = { fleet.owner },
				})
			end
		end
	end
	state.fleets = surviving
end

--- Remove `count` ships from a player: garrisons first, then parked fleets,
--- then whatever is under way.
--
-- A fleet in transit is the last thing raided. Losing an in-flight force to an
-- accounting rule reads as a bug to the player, whereas a garrison quietly
-- shrinking reads as ships being paid off.
local function strip_ships(state, player, count, events)
	if count <= 0 then return 0 end
	local removed = 0

	local owned = state_mod.owned_by(state, player)
	table.sort(owned, function(p, q)
		local a, b = state.systems[p].ships, state.systems[q].ships
		if a ~= b then return a > b end
		return p < q
	end)
	for i = 1, #owned do
		if removed >= count then break end
		local sys = state.systems[owned[i]]
		local take = min(sys.ships, count - removed)
		sys.ships = sys.ships - take
		removed = removed + take
	end

	if removed < count then
		local ordered = {}
		for i = 1, #state.fleets do
			local f = state.fleets[i]
			if f.owner == player then ordered[#ordered + 1] = f end
		end
		table.sort(ordered, function(p, q)
			local pp = state_mod.is_parked(p) and 1 or 0
			local qp = state_mod.is_parked(q) and 1 or 0
			if pp ~= qp then return pp > qp end
			if p.ships ~= q.ships then return p.ships > q.ships end
			return p.id < q.id
		end)
		for i = 1, #ordered do
			if removed >= count then break end
			local take = min(ordered[i].ships, count - removed)
			ordered[i].ships = ordered[i].ships - take
			removed = removed + take
		end
		scatter(state, events)
	end

	return removed
end

-- 1. Directives ----------------------------------------------------------------

--- Apply the standing choices in this turn's orders.
--
-- These are settings, not actions. Applying them first means a player who
-- switches research target and submits in the same turn gets the new target
-- funded this turn rather than next.
local function directives(galaxy, state, orders, mods, events)
	for i = 1, #orders do
		local order = orders[i]
		local who = order.player
		local player = state.players[who]
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
							player = who, tech = id, reason = why,
							visible_to = { who },
						})
					end
				end

			elseif order.kind == "build" then
				local at = order.at
				local sys = state.systems[at]
				local reason = nil
				if not sys then
					reason = "no such system"
				elseif sys.owner ~= who then
					reason = "you do not hold it"
				end

				if not reason and (order.building == nil or order.building == "") then
					-- Cancelling refunds nothing: the yard has already been
					-- poured. It stops the drain, which is the point.
					sys.building = nil
				elseif not reason then
					local ok, why = buildings.can_start(galaxy, at, sys, order.building)
					if not ok then
						reason = why
					elseif not sys.building or sys.building.kind ~= order.building then
						sys.building = { kind = order.building, paid = 0 }
					end
				end

				if reason then
					emit(events, {
						kind = "order_rejected", turn = state.turn,
						player = who, at = at, building = order.building,
						reason = reason, visible_to = { who },
					})
				end
			end
		end
	end
end

-- 2. Growth --------------------------------------------------------------------

local function growth(galaxy, state, mods, summaries)
	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner ~= 0 then
			local s = summaries[sys.owner]
			local m = mods[sys.owner]
			local capacity = systems.capacity(galaxy, id, m)
			if capacity > 0 then
				-- Growth on remaining headroom, so an empty world fills quickly
				-- and a full one stagnates. At least one a turn, because
				-- floor(headroom * rate) reaches zero once headroom drops below
				-- 1/rate and every world stalled a few percent short forever.
				local headroom = capacity - sys.population
				if headroom > 0 then
					sys.population = min(capacity, sys.population
						+ max(1, floor(headroom * m.growth)))
				elseif headroom < 0 then
					-- Capacity can fall: a captured world loses the previous
					-- owner's technology.
					sys.population = capacity
				end
				if s then s.colonies = s.colonies + 1 end
			end
			if s then
				s.systems = s.systems + 1
				s.population = s.population + sys.population
			end
		end
	end
end

-- 3. Industry -------------------------------------------------------------------

--- Turn every held system's output into a building or into ships, and pool
--- research.
--
-- One axis: a system produces build points, and they go to whatever it is
-- building or to hulls. There is no second currency and nothing to ship around.
local function industry(galaxy, state, mods, events, summaries)
	-- The population ceiling first, so production is not fighting attrition.
	for i = 1, #state.players do
		local m = mods[i]
		local supported = floor(state_mod.population_of(state, i) * m.cap)
		local have = state_mod.ships_of(state, i)
		if have > supported then
			local excess = floor((have - supported) * rules.over_cap_attrition)
			if excess > 0 then
				local shed = strip_ships(state, i, excess, events)
				if shed > 0 then
					emit(events, {
						kind = "attrition", turn = state.turn, player = i,
						ships = shed, reason = "over capacity",
						visible_to = { i },
					})
					local s = summaries[i]
					if s then s.scrapped = s.scrapped + shed end
				end
			end
		end
	end

	local owned = {}
	for i = 1, #state.players do owned[i] = state_mod.owned_by(state, i) end

	-- Holding a whole region pays better than holding most of one. Without it
	-- there is no reason to go back for the last stubborn outpost, and the map
	-- fills with half-taken regions nobody finishes.
	local held = regions_mod.control(galaxy, state)

	for i = 1, #state.players do
		local m = mods[i]
		local player = state.players[i]
		local s = summaries[i]
		local research = 0

		for k = 1, #owned[i] do
			local id = owned[i][k]
			local sys = state.systems[id]

			research = research + systems.research(galaxy, id, sys, m)

			local output = floor(systems.output(galaxy, id, sys, m, sys.buildings)
				* regions_mod.bonus(galaxy, held, id, i))
			if s then s.output = s.output + output end

			-- Anything under construction takes the whole stream until it is
			-- paid off, and the overflow on the turn it completes goes to hulls.
			if output > 0 and sys.building then
				local level = sys.buildings[sys.building.kind] or 0
				local cost = buildings.cost(sys.building.kind, level, m.building_cost)
				if not cost then
					-- Reached maximum some other way; stop draining the world.
					sys.building = nil
				else
					sys.building.paid = sys.building.paid + output
					if sys.building.paid >= cost then
						local spare = sys.building.paid - cost
						local kind = sys.building.kind
						sys.buildings[kind] = level + 1
						sys.building = nil
						emit(events, {
							kind = "building_complete", turn = state.turn,
							player = i, at = id, building = kind, level = level + 1,
						})
						if s then s.buildings_done = s.buildings_done + 1 end
						output = spare
					else
						output = 0
					end
				end
			end

			if output > 0 then
				local built = floor(output / m.ship_cost)
				if built > 0 then
					-- Into the garrison, not into a fleet: production landing in
					-- fleets creates one per system and the list becomes noise.
					sys.ships = sys.ships + built
					if s then s.built = s.built + built end
				end
			end
		end

		player.research = player.research + floor(research)
		if s then s.research = floor(research) end
	end
end

-- 4. Research -------------------------------------------------------------------

--- Buy the chosen technology if the pool now covers it.
local function research(state, mods, events, summaries)
	for i = 1, #state.players do
		local player = state.players[i]
		local target = player.researching
		if target then
			if not tech_mod.can_research(player.tech, target) then
				player.researching = nil
			else
				local cost = tech_mod.cost_of(target, mods[i].tech_cost)
				if player.research >= cost then
					player.research = player.research - cost
					player.tech[target] = true
					player.researching = nil
					-- Rebuilt now, because the rest of the turn reads it.
					mods[i] = modifiers.of(player)
					emit(events, {
						kind = "research_complete", turn = state.turn,
						player = i, tech = target, visible_to = { i },
					})
					local s = summaries[i]
					if s then s.researched = target end
				end
			end
		end
	end
end

-- 5. Fleet orders ---------------------------------------------------------------

--- Turn a list of places to visit into a lane-by-lane route.
--
-- The player names *where* to go; the pathfinder works out how, so fleets never
-- move in straight lines and a route can be plotted around a defended world.
-- Returns nil plus a reason if any leg is unreachable.
--- Expand a list of waypoints into the lane-by-lane route a fleet will fly.
--
-- Exported because the client needs to *draw* the route the moment an order is
-- issued, and a preview computed by a different implementation is a preview that
-- can lie. There is one function, and the server runs it for both purposes -
-- see `game.route` in server/modules/game_rpc.lua.
function M.expand_route(galaxy, lengths, from, fixed, waypoints, hops_allowed)
	local route, hops = {}, 0
	-- A fleet already in a lane must finish it before it can turn, so its
	-- current leg is fixed and everything is plotted from the far end.
	if fixed then
		route[1] = fixed
		from = fixed
		hops = 1
	end
	for w = 1, #waypoints do
		local to = math.floor(waypoints[w])
		if to ~= from then
			local leg = path_mod.find(galaxy, lengths, from, to, hops_allowed - hops)
			if not leg or #leg == 0 then return nil, "no route" end
			for h = 1, #leg do route[#route + 1] = leg[h] end
			hops = hops + #leg
			from = to
		end
	end
	return route
end

local expand_route = M.expand_route

--- Launch, redirect and stand down. Invalid orders are dropped with a reason
--- rather than silently ignored, so a client can show why.
--
-- Three verbs, because that is what the two gestures on the map need: tap a
-- world and a destination (launch), tap a fleet and a destination (move), or
-- tell a fleet to stop being one (garrison). There is no split verb - a move
-- carries an optional ship count instead, since splitting is only ever
-- something you do in order to send part of a force somewhere.
local function fleet_orders(galaxy, state, orders, mods, lengths, events)
	for i = 1, #orders do
		local order = orders[i]
		local who = order.player
		local m = mods[who]
		local kind = order.kind

		local function reject(reason, extra)
			local e = {
				kind = "order_rejected", turn = state.turn,
				player = who, reason = reason, visible_to = { who },
			}
			if extra then
				for k, v in pairs(extra) do e[k] = v end
			end
			emit(events, e)
		end

		if kind == "launch" then
			local at = order.at
			local sys = state.systems[at]
			local ships = order.ships and floor(order.ships) or 0
			local waypoints = order.route
			if not sys then
				reject("no such system", { at = at })
			elseif sys.owner ~= who then
				reject("you do not hold it", { at = at })
			elseif type(waypoints) ~= "table" or #waypoints == 0 then
				reject("nowhere to send them", { at = at })
			else
				-- Clamp rather than refuse: the player ordered against the state
				-- they last saw, which may be a turn out of date.
				if ships < 1 then ships = sys.ships end
				ships = min(ships, sys.ships)
				if ships < 1 then
					reject("no ships in the garrison", { at = at })
				elseif not state_mod.can_raise(state, who) then
					-- The cap is the shape of the game, so this is a refusal
					-- with a reason rather than a silent clamp: the player has
					-- to choose which front to give up.
					reject("no commander to spare", { at = at })
				else
					local route, why = expand_route(galaxy, lengths, at, nil,
						waypoints, m.hops)
					if not route or #route == 0 then
						reject(why or "no route", { at = at, to = waypoints[#waypoints] })
					else
						-- A fresh commander leads what a fresh commander can.
						-- The rest stays in the garrison rather than being lost,
						-- so over-ordering costs nothing but the trip.
						local fleet = state_mod.add_fleet(state, who, at, 0)
						local led = min(ships, commanders.command(fleet, m))
						fleet.ships = led
						sys.ships = sys.ships - led
						fleet.route = route
						emit(events, {
							kind = "fleet_launched", turn = state.turn, player = who,
							at = at, fleet = fleet.id, name = fleet.name,
							rank = commanders.rank(fleet.level),
							ships = led, left_behind = ships - led,
							to = route[#route],
							visible_to = { who },
						})
					end
				end
			end

		elseif kind == "move" then
			local fleet = state_mod.fleet_by_id(state, order.fleet)
			if not fleet or fleet.owner ~= who then
				reject("no such fleet", { fleet = order.fleet })
			else
				local waypoints = order.route
				local parked = state_mod.is_parked(fleet)

				-- A detachment: part of a parked fleet peels off and goes.
				local detach = order.ships and floor(order.ships) or nil
				if detach and parked and detach >= 1 and detach < fleet.ships then
					fleet.ships = fleet.ships - detach
					fleet = state_mod.add_fleet(state, who, fleet.at, detach)
				end

				if type(waypoints) ~= "table" or #waypoints == 0 then
					-- An empty route recalls the fleet: it holds where it is, or
					-- finishes the lane it is in and stops.
					fleet.route = parked and {} or { fleet.route[1] }
				else
					local route, why = expand_route(galaxy, lengths, fleet.at,
						(not parked) and fleet.route[1] or nil, waypoints, m.hops)
					if not route then
						reject(why, { fleet = order.fleet, to = waypoints[#waypoints] })
					else
						fleet.route = route
					end
				end
			end

		elseif kind == "garrison" then
			local fleet = state_mod.fleet_by_id(state, order.fleet)
			if not fleet or fleet.owner ~= who then
				reject("no such fleet", { fleet = order.fleet })
			elseif not state_mod.is_parked(fleet) then
				reject("a fleet under way cannot stand down", { fleet = order.fleet })
			else
				local sys = state.systems[fleet.at]
				if not sys or sys.owner ~= who then
					reject("you do not hold it", { fleet = order.fleet })
				else
					local handed_over = fleet.ships
					sys.ships = sys.ships + handed_over
					-- Retired outright, not left as an empty force. It used to
					-- be zeroed and swept up by a prune at the end of the phase;
					-- now that a force with no ships means "a commander who was
					-- beaten" it has to say which of the two this is, or
					-- standing down demotes the officer and holds the slot.
					state_mod.retire_fleet(state, fleet)
					emit(events, {
						kind = "fleet_stood_down", turn = state.turn, player = who,
						at = sys and fleet.at, name = fleet.name,
						ships = handed_over, visible_to = { who },
					})
				end
			end
		end
	end

	scatter(state, events)
end

-- 5b. Resupply ------------------------------------------------------------------

--- A commander sitting on one of your worlds tops up from its garrison.
--
-- This is where production reaches the front. Ships accumulate in garrisons
-- (industry puts them there deliberately, so the map does not fill with one
-- force per system), and a commander parked on a world draws from it up to what
-- they can lead. Parking one somewhere is therefore the standing instruction
-- "send what you build here to the front", which is the right shape of decision
-- for a game checked twice a day.
--
-- It is also what makes a scattered commander recoverable. Without it a beaten
-- officer sat at a refuge with no ships forever, holding one of the four slots
-- the player is allowed and unable to do anything with it - which froze the
-- game outright once every player had lost four battles.
local function resupply(state, mods, events)
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if #fleet.route == 0 and fleet.progress == 0 then
			local sys = state.systems[fleet.at]
			if sys and sys.owner == fleet.owner and (sys.ships or 0) > 0 then
				local room = commanders.command(fleet, mods[fleet.owner]) - fleet.ships
				local taken = min(room, sys.ships)
				if taken > 0 then
					sys.ships = sys.ships - taken
					fleet.ships = fleet.ships + taken
					emit(events, {
						kind = "reinforced", turn = state.turn,
						player = fleet.owner, fleet = fleet.id, name = fleet.name,
						at = fleet.at, ships = taken, total = fleet.ships,
						visible_to = { fleet.owner },
					})
				end
			end
		end
	end
end

-- 6. Movement -------------------------------------------------------------------

--- Advance every fleet along its route.
--
-- Unclaimed systems are taken in passing and do not stop the fleet, so a route
-- through a chain of barren waypoints sweeps them all up - which is exactly what
-- waypoints are for. A system somebody else holds *does* stop it: lanes can be
-- blockaded, and you cannot slip a fleet past a defended border.
--
-- If two players' fleets pass through the same neutral system on the same turn,
-- the earlier fleet in the list claims it and the later one arrives at a hostile
-- system and stops. That is arbitrary but deterministic, and it reads as "we got
-- there first".
local function movement(galaxy, state, mods, lengths, events)
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if #fleet.route > 0 then
			-- Each commander moves at their own pace: level is most of it, race
			-- and technology scale it. A green officer is slower than a lane is
			-- long, which is what puts forces in transit where they can be
			-- caught.
			local budget = commanders.speed(fleet, mods[fleet.owner])
			local blocked = false

			while budget > 0 and #fleet.route > 0 and not blocked do
				local next_id = fleet.route[1]
				local leg = path_mod.lane_length(lengths, fleet.at, next_id) or 0
				local remaining = leg - fleet.progress

				if budget >= remaining then
					budget = budget - remaining
					fleet.at = next_id
					fleet.progress = 0
					table.remove(fleet.route, 1)

					local sys = state.systems[next_id]
					if sys.owner == 0 then
						sys.owner = fleet.owner
						emit(events, {
							kind = "claimed", turn = state.turn,
							at = next_id, player = fleet.owner, ships = fleet.ships,
						})
					elseif sys.owner ~= fleet.owner then
						fleet.route = {}
						blocked = true
					end
				else
					fleet.progress = fleet.progress + budget
					budget = 0
				end
			end
		end
	end
end

-- 7. Interception ---------------------------------------------------------------

--- The multiplier the senior officer present applies to a side.
--
-- The most experienced commander leads: a battle is not fought better because
-- three green captains turned up. A garrison with no commander gets nothing,
-- which is what makes stationing one on a threatened world worth doing.
local function senior_tactics(list, m)
	local best = 1
	for f = 1, #(list or {}) do
		local t = commanders.tactics(list[f], m)
		if t > best then best = t end
	end
	return best
end

--- Split experience across the commanders who won it, by what each brought.
--
-- Proportional rather than shared in full, so stacking every commander into one
-- battle promotes the group no faster than fighting it alone would.
local function award_xp(list, contributions, total, amount, events, turn)
	if amount <= 0 or total <= 0 then return end
	for f = 1, #list do
		local fleet = list[f]
		local share = (contributions[fleet.id] or 0) / total
		local gained = commanders.award(fleet, floor(amount * share))
		if gained > 0 then
			emit(events, {
				kind = "commander_promoted", turn = turn,
				player = fleet.owner, fleet = fleet.id, name = fleet.name,
				level = fleet.level, rank = commanders.rank(fleet.level),
				visible_to = { fleet.owner },
			})
		end
	end
end

--- What each fleet in a list brought, and the total. Taken before a battle
--- rewrites `ships` with the survivors.
local function contributions_of(list)
	local by_id, total = {}, 0
	for f = 1, #(list or {}) do
		by_id[list[f].id] = list[f].ships
		total = total + list[f].ships
	end
	return by_id, total
end

--- One engagement. Returns whether the attacker won, and the winner's survivors.
--
-- A Lanchester-style exchange: the loser is destroyed and the winner keeps the
-- fraction of its force that the margin of victory implies, so a narrow win is
-- expensive and an overwhelming one nearly free.
local function engage(r, att, att_mult, def, def_mult)
	local variance = rules.combat_variance
	local a = att * att_mult * r:range(1 - variance, 1 + variance)
	local d = def * def_mult * r:range(1 - variance, 1 + variance)
	if d <= 0 then return true, att, 0 end
	if a <= 0 then return false, def, att end
	if a > d then
		return true, max(1, floor(att * (1 - d / a))), def
	end
	return false, max(1, floor(def * (1 - a / d))), att
end

--- Hostile fleets that end the turn in the same lane fight there.
--
-- A deliberate abstraction: a lane is a narrow corridor, so two hostile forces
-- inside one engage regardless of where along it they happen to be or which way
-- they are pointing. Modelling the exact crossing point would need the whole
-- path each fleet swept this turn, and the corridor reading is the one players
-- will expect anyway.
local function interception(state, mods, r, events, summaries)
	local lanes, order = {}, {}
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		local next_id = fleet.route[1]
		if next_id and fleet.progress > 0 then
			local a, b = fleet.at, next_id
			if a > b then
				local swap = a
				a = b
				b = swap
			end
			local key = a * 100000 + b
			local bucket = lanes[key]
			if not bucket then
				bucket = { a = a, b = b, owners = {}, order = {} }
				lanes[key] = bucket
				order[#order + 1] = key
			end
			if not bucket.owners[fleet.owner] then
				bucket.owners[fleet.owner] = {}
				bucket.order[#bucket.order + 1] = fleet.owner
			end
			local list = bucket.owners[fleet.owner]
			list[#list + 1] = fleet
		end
	end
	table.sort(order)

	for k = 1, #order do
		local bucket = lanes[order[k]]
		if #bucket.order >= 2 then
			table.sort(bucket.order)
			-- Two sides at a time, in player order, so a three-way meeting
			-- resolves as a sequence rather than needing its own rules.
			local standing = bucket.order[1]
			for oi = 2, #bucket.order do
				local challenger = bucket.order[oi]
				local function total(who)
					local t = 0
					local list = bucket.owners[who]
					for f = 1, #list do t = t + list[f].ships end
					return t
				end
				local held, came = total(standing), total(challenger)
				if held > 0 and came > 0 then
					local att_list = bucket.owners[challenger]
					local def_list = bucket.owners[standing]
					local att_share, att_total = contributions_of(att_list)
					local def_share, def_total = contributions_of(def_list)
					local won, survivors = engage(r,
						came, mods[challenger].attack
							* senior_tactics(att_list, mods[challenger]),
						held, mods[standing].defence
							* senior_tactics(def_list, mods[standing]))
					local winner = won and challenger or standing
					local loser = won and standing or challenger

					local function wipe(who)
						local list = bucket.owners[who]
						for f = 1, #list do list[f].ships = 0 end
					end
					local function reduce(who, keep)
						local list = bucket.owners[who]
						-- Losses land on the smallest fleets first, so a
						-- flagship survives a mauling.
						table.sort(list, function(p, q)
							if p.ships ~= q.ships then return p.ships < q.ships end
							return p.id < q.id
						end)
						local remaining = keep
						for f = #list, 1, -1 do
							local take = min(list[f].ships, remaining)
							list[f].ships = take
							remaining = remaining - take
						end
					end

					wipe(loser)
					reduce(winner, survivors)

					emit(events, {
						kind = "intercepted", turn = state.turn,
						a = bucket.a, b = bucket.b,
						attacker = challenger, defender = standing,
						attacker_ships = came, defender_ships = held,
						winner = winner, survivors = survivors,
					})
					-- Experience is enemy ships destroyed, which is a number
					-- the player can already read off the battle report.
					if won then
						award_xp(att_list, att_share, att_total, held, events, state.turn)
					else
						award_xp(def_list, def_share, def_total, came, events, state.turn)
					end
					local ws = summaries[winner]
					if ws then ws.won = ws.won + 1 end
					local ls = summaries[loser]
					if ls then ls.lost_fleets = ls.lost_fleets + 1 end
					standing = winner
				elseif came > 0 then
					standing = challenger
				end
			end
		end
	end

	scatter(state, events)
end

-- 8. Battles --------------------------------------------------------------------

local function battles(galaxy, state, mods, r, events, summaries)
	-- Fleets sitting at a system, grouped by system. Sorted so resolution order
	-- never depends on table iteration order.
	local at_system, ids = {}, {}
	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if fleet.progress == 0 then
			local bucket = at_system[fleet.at]
			if not bucket then
				bucket = { owners = {}, order = {} }
				at_system[fleet.at] = bucket
				ids[#ids + 1] = fleet.at
			end
			if not bucket.owners[fleet.owner] then
				bucket.owners[fleet.owner] = {}
				bucket.order[#bucket.order + 1] = fleet.owner
			end
			local list = bucket.owners[fleet.owner]
			list[#list + 1] = fleet
		end
	end
	table.sort(ids)

	for k = 1, #ids do
		local id = ids[k]
		local bucket = at_system[id]
		local sys = state.systems[id]
		table.sort(bucket.order)

		for oi = 1, #bucket.order do
			local attacker = bucket.order[oi]
			if sys.owner ~= attacker and sys.owner ~= 0 then
				local defender = sys.owner
				local att_ships = 0
				local list = bucket.owners[attacker]
				for f = 1, #list do att_ships = att_ships + list[f].ships end

				local def_list = bucket.owners[defender] or {}
				local def_fleet = 0
				for f = 1, #def_list do def_fleet = def_fleet + def_list[f].ships end
				local garrison = sys.ships or 0
				local def_ships = garrison + def_fleet
				local def_static = floor(systems.defence(galaxy, id, sys, sys.buildings)
					* mods[defender].fortress)

				if att_ships > 0 then
					local att_share, att_total = contributions_of(list)
					local def_share, def_total = contributions_of(def_list)
					local att_tactics = senior_tactics(list, mods[attacker])
					local def_tactics = senior_tactics(def_list, mods[defender])
					local won, survivors = engage(r,
						att_ships, mods[attacker].attack * att_tactics,
						def_ships + def_static, mods[defender].defence * def_tactics)

					emit(events, {
						kind = "battle", turn = state.turn, at = id,
						attacker = attacker, defender = defender,
						attacker_ships = att_ships,
						defender_ships = def_ships,
						defender_garrison = garrison,
						defence_static = def_static,
						attacker_tactics = att_tactics,
						defender_tactics = def_tactics,
						winner = won and attacker or defender,
						survivors = survivors,
						captured = won,
					})

					-- Before either side's `ships` is rewritten with survivors.
					if won then
						award_xp(list, att_share, att_total, def_ships, events, state.turn)
					else
						award_xp(def_list, def_share, def_total, att_ships, events, state.turn)
					end

					if won then
						sys.ships = 0
						for f = 1, #def_list do def_list[f].ships = 0 end
						-- The attacker's force is consolidated into its first
						-- fleet; a victorious army does not stay in packets.
						local keep = survivors
						table.sort(list, function(p, q) return p.id < q.id end)
						for f = 1, #list do
							local take = min(list[f].ships, keep)
							list[f].ships = take
							keep = keep - take
						end
						sys.owner = attacker
						sys.population = floor(sys.population * mods[attacker].capture_keep)
						-- Buildings survive: taking a fortified world is meant
						-- to be a prize, and it now defends its new owner.
						if sys.home_of ~= 0 and sys.home_of ~= attacker then
							sys.home_of = 0
						end
						-- Anything half-built belonged to the previous owner.
						sys.building = nil
						local s = summaries[attacker]
						if s then s.captured = s.captured + 1 end
						local d = summaries[defender]
						if d then d.lost = d.lost + 1 end
					else
						-- Casualties fall on the garrison first, then on any
						-- fleet stationed here - so keeping a fleet on a world
						-- is worth doing - and never on the planet's own guns,
						-- which are not something that can be shot down.
						local losses = min(def_ships, (def_ships + def_static) - survivors)
						if losses < 0 then losses = 0 end
						local from_garrison = min(sys.ships, losses)
						sys.ships = sys.ships - from_garrison
						local remaining = losses - from_garrison
						table.sort(def_list, function(p, q)
							if p.ships ~= q.ships then return p.ships < q.ships end
							return p.id < q.id
						end)
						for f = 1, #def_list do
							local take = min(def_list[f].ships, remaining)
							def_list[f].ships = def_list[f].ships - take
							remaining = remaining - take
						end
						for f = 1, #list do list[f].ships = 0 end
						local s = summaries[attacker]
						if s then s.lost_fleets = s.lost_fleets + 1 end
					end
				end
			end
		end
	end

	scatter(state, events)
end

-- 9. Aftermath ------------------------------------------------------------------

local function aftermath(galaxy, state, mods, events, summaries)
	-- Forces are deliberately *not* consolidated any more. Folding two
	-- co-located fleets into one used to keep the list readable, and under a
	-- commander cap it is no longer needed for that - but it would now quietly
	-- destroy an officer for the crime of parking next to a colleague, which is
	-- the last thing a game about attachment to them should do. Standing a
	-- force down is what the `garrison` order is for.

	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			emit(events, { kind = "eliminated", turn = state.turn, player = i })
		end
	end

	-- Region control, and with it the only way the game ends.
	--
	-- Recomputed rather than tracked: it is a pure function of who owns what,
	-- and storing it would be one more thing to keep in step across a JSON
	-- round trip for no gain.
	local held = regions_mod.control(galaxy, state)
	local previous = state.regions_held or {}
	for r = 1, #held do
		if held[r] ~= (previous[r] or 0) then
			emit(events, {
				kind = "region_control", turn = state.turn, region = r,
				name = galaxy.regions[r] and galaxy.regions[r].name,
				player = held[r], from = previous[r] or 0,
			})
		end
	end
	state.regions_held = held

	if not state.winner then
		local needed = regions_mod.needed(galaxy)
		local tally = regions_mod.tally(galaxy, state, held)
		for i = 1, #state.players do
			if (tally[i] or 0) >= needed and state.players[i].alive then
				state.winner = i
				emit(events, {
					kind = "victory", turn = state.turn, player = i,
					regions = tally[i], needed = needed,
				})
			end
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
			s.kind = "turn_summary"
			s.turn = state.turn
			s.player = i
			s.ships = state_mod.ships_of(state, i)
			s.garrisoned = state_mod.garrisons_of(state, i)
			s.fleets = 0
			for f = 1, #state.fleets do
				if state.fleets[f].owner == i then s.fleets = s.fleets + 1 end
			end
			s.research_banked = player.research
			s.researching = player.researching
			s.visible_to = { i }
			emit(events, s)
		end
	end
end

--- Decide who may see each event.
--
-- Participants always do. Everyone else only if the place it happened is visible
-- to them at the end of the turn, so a battle on the far side of the map is not
-- broadcast.
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
				local part = (event.player == i) or (event.attacker == i)
					or (event.defender == i)
				local where = (event.at and visible[i][event.at])
					or (event.a and visible[i][event.a])
					or (event.b and visible[i][event.b])
				if part or where then who[#who + 1] = i end
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
			systems = 0, colonies = 0, population = 0,
			output = 0, research = 0, built = 0, buildings_done = 0,
			scrapped = 0, captured = 0, lost = 0, won = 0, lost_fleets = 0,
		}
		mods[i] = modifiers.of(state.players[i])
	end

	directives(galaxy, state, orders, mods, events)
	growth(galaxy, state, mods, summaries)
	industry(galaxy, state, mods, events, summaries)
	research(state, mods, events, summaries)
	fleet_orders(galaxy, state, orders, mods, lengths, events)
	resupply(state, mods, events)
	movement(galaxy, state, mods, lengths, events)
	interception(state, mods, r, events, summaries)
	battles(galaxy, state, mods, r, events, summaries)
	aftermath(galaxy, state, mods, events, summaries)
	apply_visibility(galaxy, state, events)

	return events
end

return M
