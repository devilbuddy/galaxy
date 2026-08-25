--- One turn of the simulation.
--
-- `M.turn(galaxy, state, orders, lengths)` advances exactly one turn and
-- returns the events it produced. It is a pure function of its inputs plus a
-- per-turn seeded stream, so a turn replays identically and a whole game is
-- reconstructable from `(seed, order history)`.
--
-- The game is being rebuilt from the ground up. A turn is currently four
-- phases, not nine:
--
--   **orders → movement → aftermath → visibility**
--
-- Production, research and buildings have all been taken out; combat has been
-- built back, as one comparison. Captains move along lanes, claim what they
-- pass through, and take ground off each other when they have the strength to.
--
-- Two invariants survive from the version this replaced, and both must:
--
--   * **Never iterate a hash table with `pairs` where the order affects the
--     output.** Lua's `pairs` order is unspecified, and the server and client
--     have to agree exactly.
--   * **Every event carries who may see it** (`visible_to`), applied at the end
--     against what each player can actually observe.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local state_mod = require("galaxy.sim.state")
local path_mod = require("galaxy.sim.path")
local view = require("galaxy.sim.view")
local commanders = require("galaxy.sim.commanders")
local regions_mod = require("galaxy.sim.regions")
local modifiers = require("galaxy.sim.modifiers")
local systems_mod = require("galaxy.sim.systems")

local floor = math.floor
local min = math.min

local M = {}

local function emit(events, e)
	events[#events + 1] = e
	return e
end

-- 1. Orders ---------------------------------------------------------------------

--- Expand a list of waypoints into the lane-by-lane route a captain will fly.
--
-- Exported because the client draws the route the moment an order is issued,
-- and a preview computed by a different implementation is a preview that can
-- lie. There is one function, and the server runs it for both purposes - see
-- `game.route` in server/modules/game_rpc.lua.
function M.expand_route(galaxy, lengths, from, fixed, waypoints, hops_allowed)
	local route, hops = {}, 0
	-- A captain already in a lane must finish it before turning, so the current
	-- leg is fixed and everything is plotted from its far end.
	if fixed then
		route[1] = fixed
		from = fixed
		hops = 1
	end
	for w = 1, #waypoints do
		local to = floor(waypoints[w])
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

--- Give captains their orders. There is one verb: move.
--
-- Invalid orders are dropped with a reason rather than silently ignored, so the
-- client can say what happened. Whether an order is *legal* depends on state
-- that has moved on since the player issued it, which is why the check is here
-- and not in the RPC.
local function captain_orders(galaxy, state, orders, mods, lengths, events)
	for i = 1, #orders do
		local order = orders[i]
		local who = order.player
		local m = mods[who]

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

		if order.kind == "move" then
			local captain = state_mod.captain_by_id(state, order.captain)
			if not captain or captain.owner ~= who then
				reject("no such captain", { captain = order.captain })
			else
				local waypoints = order.route
				if type(waypoints) ~= "table" or #waypoints == 0 then
					-- An empty route is how a captain is told to stand still.
					captain.route = {}
				else
					local fixed = state_mod.next_hop(captain)
					local from = fixed or captain.at
					local route, why = expand_route(galaxy, lengths, from,
						fixed, waypoints, m.hops)
					if not route or #route == 0 then
						reject(why or "no route", {
							captain = captain.id, to = waypoints[#waypoints],
						})
					else
						captain.route = route
						emit(events, {
							kind = "captain_ordered", turn = state.turn,
							player = who, captain = captain.id, name = captain.name,
							to = route[#route], hops = #route,
							visible_to = { who },
						})
					end
				end
			end
		end
	end
end

-- 2. Movement -------------------------------------------------------------------

--- What it costs to take `id` from the player who holds it, right now.
--
-- The world's own resistance plus whatever is garrisoned on it. **Every term is
-- something the attacker can already see**: the kind of place is public map
-- data, whose capital it is is in their view, and a captain standing on it is a
-- contact they have eyes on. That is what makes the comparison below a decision
-- rather than a gamble.
--
-- Returns the total **and its parts**: the world's own resistance, and every
-- officer standing on it by name. Nothing needs the breakdown to decide the
-- battle - the decision is the total - but a fight that reports only a number
-- can never be replayed as anything more than a number, and a battle you can
-- watch is where this is going. Carrying who was there costs a table per fight
-- and is the difference between an event and a scene.
local function resistance(galaxy, state, mods, id)
	local sys = state.systems[id]
	local owner = sys.owner
	local world = systems_mod.defence(galaxy, id, sys.capital_of == owner, mods[owner])
	local total = world
	local garrison = {}
	for i = 1, #state.captains do
		local c = state.captains[i]
		if c.owner == owner and c.at == id then
			local held = commanders.strength(c, mods[owner])
			total = total + held
			garrison[#garrison + 1] = {
				captain = c.id, name = c.name,
				rank = commanders.rank(c.level or 1), strength = held,
			}
		end
	end
	return total, world, garrison
end

--- Throw the defenders of a system that has just fallen back to their capital.
--
-- Broken rather than killed, and demoted rather than deleted: with one captain
-- each, an officer who could be removed from the board would end the game for
-- their player on a single bad turn, and everyone would stop committing.
local function break_defenders(state, mods, id, owner, events)
	for i = 1, #state.captains do
		local c = state.captains[i]
		if c.owner == owner and c.at == id then
			local home = state_mod.refuge(state, c)
			c.route = {}
			c.strength = 0
			commanders.demote(c)
			c.at = home
			emit(events, {
				kind = "captain_broken", turn = state.turn,
				player = owner, captain = c.id, name = c.name,
				at = home, lost = id, rank = commanders.rank(c.level),
				visible_to = { owner },
			})
		end
	end
end

--- Move every captain as far as its turn allows, claiming and taking as it goes.
--
-- A captain crosses a whole number of lanes and always ends the turn *at* a
-- system. Movement used to be a distance covered along a lane, which meant a
-- captain could sit partway down one - a state the player could neither see at
-- fit zoom nor predict, because lane lengths are never drawn.
--
-- Unclaimed systems are taken in passing and do not stop it, so a route through
-- a chain of empty systems sweeps them all up.
--
-- **A captain attacks only when it can win.** If it cannot cover the
-- resistance it stops at the border exactly as it did before combat existed,
-- and the event says both numbers so the player can see what it would take. The
-- alternative - letting an assault fail - would mean a captain could be spent
-- to nothing by an arithmetic slip made twelve hours earlier, and would turn
-- every attack into a gamble in a game whose whole point is planning ahead.
local function movement(galaxy, state, mods, events)
	for i = 1, #state.captains do
		local captain = state.captains[i]
		local my_mods = mods[captain.owner]
		local steps = commanders.steps(captain, my_mods)
		-- Where it started, and every system it sets foot in. Nothing in the
		-- resolver reads this back; it exists because **the event log is the
		-- record of the turn**, and a log that reports only outcomes can be
		-- listed but never replayed. A captain crossing its own territory
		-- changes nothing and so emitted nothing at all, which meant the one
		-- thing a player would most want to watch - a fleet moving - was the
		-- one thing the log did not contain.
		local from, walked = captain.at, {}

		while steps > 0 and #captain.route > 0 do
			local next_id = captain.route[1]
			local sys = state.systems[next_id]
			local defender = sys.owner

			if defender ~= 0 and defender ~= captain.owner then
				local cost, world, garrison = resistance(galaxy, state, mods, next_id)
				local have = commanders.strength(captain, my_mods)
				if have < cost then
					-- Stopped *before* entering: a border you cannot cross is
					-- one you do not stand in. The route is dropped rather than
					-- held, so a captain never waits on something that may
					-- never change.
					captain.route = {}
					emit(events, {
						kind = "captain_blocked", turn = state.turn,
						player = captain.owner, captain = captain.id,
						name = captain.name, at = captain.at,
						blocked_by = next_id, held_by = defender,
						strength = have, resistance = cost,
						defence = world, garrison = garrison,
						visible_to = { captain.owner },
					})
					break
				end

				-- Taken. The garrison goes home before the system changes
				-- hands, so `refuge` is asked while the defender still holds
				-- their capital - which matters when the capital *is* the
				-- system falling.
				break_defenders(state, mods, next_id, defender, events)
				captain.strength = have - cost
				-- Promotion is reported when the *title* changes, not when the
				-- level does. Ranks span two levels each, so awarding a level
				-- announced "promoted to Captain" to someone who was already
				-- a Captain - which reads as the game not knowing what it did.
				local was_rank = commanders.rank(captain.level or 1)
				commanders.award(captain, cost)
				local now_rank = commanders.rank(captain.level or 1)
				sys.owner = captain.owner
				emit(events, {
					kind = "battle", turn = state.turn,
					at = next_id, player = captain.owner, captain = captain.id,
					name = captain.name, against = defender,
					rank = now_rank,
					-- What was brought and what was faced, both broken down.
					-- The client turns these into a sentence today and will turn
					-- them into a replay later; the resolver states facts.
					brought = have, resistance = cost,
					defence = world, garrison = garrison,
					strength = captain.strength,
					level = captain.level,
					promoted = (now_rank ~= was_rank) and now_rank or nil,
				})
			end

			captain.at = next_id
			walked[#walked + 1] = next_id
			table.remove(captain.route, 1)
			steps = steps - 1

			if sys.owner == 0 then
				sys.owner = captain.owner
				emit(events, {
					kind = "claimed", turn = state.turn,
					at = next_id, player = captain.owner,
					captain = captain.id, name = captain.name,
				})
			end
		end

		if #walked > 0 then
			emit(events, {
				kind = "captain_moved", turn = state.turn,
				player = captain.owner, captain = captain.id,
				name = captain.name, from = from, at = captain.at,
				path = walked, bound_for = captain.route[#captain.route],
				visible_to = { captain.owner },
			})
		end
	end
end

--- Strength comes back, but only on ground you hold.
--
-- An army in somebody else's space is an army out of supply: it is what stops a
-- deep raid running forever, and what makes the trip home mean something. The
-- capital is much faster, because it is the one place that will later be able
-- to build.
local function resupply(state, mods)
	for i = 1, #state.captains do
		local captain = state.captains[i]
		local sys = state.systems[captain.at]
		if sys and sys.owner == captain.owner then
			local my_mods = mods[captain.owner]
			local gain = (sys.capital_of == captain.owner)
				and rules.capital_recovery or rules.strength_recovery
			local cap = commanders.max_strength(captain, my_mods)
			captain.strength = min(cap, commanders.strength(captain, my_mods) + gain)
		end
	end
end

-- 3. Aftermath ------------------------------------------------------------------

local function aftermath(galaxy, state, mods, events, summaries)
	resupply(state, mods)

	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			emit(events, { kind = "eliminated", turn = state.turn, player = i })
		end
	end

	-- Region control, and with it the only way the game ends. Recomputed rather
	-- than tracked: it is a pure function of who owns what.
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
					regions = tally[i], needed = needed, by = "regions",
				})
			end
		end

		-- The other way to win, which only became reachable when capitals
		-- became takeable: everyone else is out. Without this a two-player game
		-- that ended in a conquest simply carried on with nobody to play
		-- against and no winner ever declared.
		if not state.winner and #state.players > 1 then
			local alive, last = 0, nil
			for i = 1, #state.players do
				if state.players[i].alive then
					alive = alive + 1
					last = i
				end
			end
			if alive == 1 then
				state.winner = last
				emit(events, {
					kind = "victory", turn = state.turn, player = last,
					regions = tally[last] or 0, needed = needed,
					by = "survival",
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
			s.kind = "turn_summary"
			s.turn = state.turn
			s.player = i
			s.systems = state_mod.holdings_of(state, i)
			s.regions = 0
			for r = 1, #state.regions_held do
				if state.regions_held[r] == i then s.regions = s.regions + 1 end
			end
			s.visible_to = { i }
			emit(events, s)
		end
	end
end

-- 4. Visibility -----------------------------------------------------------------

--- Decide who may see each event.
--
-- Participants always do. Everyone else only if the place it happened is
-- visible to them at the end of the turn, so something on the far side of the
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
				if event.player == i or (event.at and visible[i][event.at]) then
					who[#who + 1] = i
				end
			end
			event.visible_to = who
		end
	end
end

-- The turn ----------------------------------------------------------------------

function M.turn(galaxy, state, orders, lengths)
	lengths = lengths or path_mod.lane_lengths(galaxy)
	orders = orders or {}

	state.turn = state.turn + 1
	-- Seeded per turn, so replaying a turn gives an identical result. Nothing
	-- rolls dice - combat is a comparison, deliberately, so that a player can
	-- work out the answer before committing - but the stream stays because the
	-- turn is the right place to derive one from and something will want it.
	local _ = rng.stream(state.seed, "turn:" .. state.turn)

	local events = {}
	local summaries = {}
	local mods = {}
	for i = 1, #state.players do
		summaries[i] = { claimed = 0, taken = 0 }
		mods[i] = modifiers.of(state.players[i])
	end

	captain_orders(galaxy, state, orders, mods, lengths, events)
	movement(galaxy, state, mods, events)

	for e = 1, #events do
		local kind = events[e].kind
		local s = summaries[events[e].player]
		if s then
			if kind == "claimed" then s.claimed = s.claimed + 1
			elseif kind == "battle" then s.taken = s.taken + 1 end
		end
	end

	aftermath(galaxy, state, mods, events, summaries)
	apply_visibility(galaxy, state, events)

	return events
end

return M
