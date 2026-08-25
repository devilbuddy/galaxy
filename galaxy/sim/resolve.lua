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
-- Production, research, buildings and combat have all been taken out. What is
-- left is the skeleton they will be built back onto: captains move along lanes,
-- claim what they pass through, and stop at a border they have no army to
-- cross.
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

--- Move every captain as far as its turn allows, claiming as it goes.
--
-- A captain crosses a whole number of lanes and always ends the turn *at* a
-- system. Movement used to be a distance covered along a lane, which meant a
-- captain could sit partway down one - a state the player could neither see at
-- fit zoom nor predict, because lane lengths are never drawn.
--
-- Unclaimed systems are taken *in passing* and do not stop the captain, so a
-- route through a chain of empty systems sweeps them all up. A system somebody
-- else holds does stop it: there is no army to push through with, and
-- pretending otherwise would make borders meaningless.
local function movement(galaxy, state, mods, events)
	for i = 1, #state.captains do
		local captain = state.captains[i]
		local steps = commanders.steps(captain, mods[captain.owner])

		while steps > 0 and #captain.route > 0 do
			local next_id = captain.route[1]
			local sys = state.systems[next_id]

			if sys.owner ~= 0 and sys.owner ~= captain.owner then
				-- Stopped *before* entering: a border you cannot cross is one
				-- you do not stand in. The route is dropped rather than held,
				-- so a captain never waits on something that may never change.
				captain.route = {}
				emit(events, {
					kind = "captain_blocked", turn = state.turn,
					player = captain.owner, captain = captain.id,
					name = captain.name, at = captain.at, blocked_by = next_id,
					held_by = sys.owner, visible_to = { captain.owner },
				})
				break
			end

			captain.at = next_id
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
	end
end

-- 3. Aftermath ------------------------------------------------------------------

local function aftermath(galaxy, state, events, summaries)
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
	-- rolls dice yet; the stream is here because combat will.
	local _ = rng.stream(state.seed, "turn:" .. state.turn)

	local events = {}
	local summaries = {}
	local mods = {}
	for i = 1, #state.players do
		summaries[i] = { claimed = 0 }
		mods[i] = modifiers.of(state.players[i])
	end

	captain_orders(galaxy, state, orders, mods, lengths, events)
	movement(galaxy, state, mods, events)

	for e = 1, #events do
		if events[e].kind == "claimed" then
			local s = summaries[events[e].player]
			if s then s.claimed = s.claimed + 1 end
		end
	end

	aftermath(galaxy, state, events, summaries)
	apply_visibility(galaxy, state, events)

	return events
end

return M
