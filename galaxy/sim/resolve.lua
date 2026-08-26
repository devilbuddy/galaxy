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
--   **orders → movement → logistics → aftermath → visibility**
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
local buildings = require("galaxy.sim.buildings")
local units = require("galaxy.sim.units")

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
local function captain_orders(galaxy, state, orders, mods, lengths, events, pending)
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

		if order.kind == "build" then
			-- Recorded, not acted on. Everything it depends on - who holds the
			-- system, what is already there, whether the purse can pay - may
			-- move between now and the logistics phase, so the check is there.
			local at = order.at and floor(order.at)
			if at and buildings.exists(order.building) then
				pending[#pending + 1] = {
					player = who, at = at, building = order.building,
				}
			else
				reject("no such building", { building = order.building })
			end

		elseif order.kind == "recruit" then
			local at = order.at and floor(order.at)
			if at then
				pending[#pending + 1] = { player = who, at = at, recruit = true }
			else
				reject("nowhere to raise them")
			end

		elseif order.kind == "resupply" then
			local captain = state_mod.captain_by_id(state, order.captain)
			if not captain or captain.owner ~= who then
				reject("no such captain", { captain = order.captain })
			else
				-- **A mix, not a count.** Composition is chosen at the moment a
				-- captain loads, which is when the player already knows what
				-- they are marching at - not twenty turns earlier at whichever
				-- colony happened to build it.
				--
				-- Recorded rather than acted on: a captain buys where it *ends*
				-- the turn, so an order can move onto a colony and load there
				-- in one go. Movement has not run yet.
				captain.buying = units.normalise(order.units)
			end

		elseif order.kind == "move" then
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
-- **Two halves, both public, and an army is aimed at one or the other.** The
-- world's own fortification is derived from the star and whatever has been
-- built on it; the fleet is whoever is standing there. Returns them separately
-- because they are separately compared, and the garrison by name because a
-- fight that reports only numbers can never be replayed as anything more than
-- numbers.
local function resistance(galaxy, state, mods, id)
	local sys = state.systems[id]
	local owner = sys.owner
	local fortification = systems_mod.defence(galaxy, id, sys.capital_of == owner,
		mods[owner]) + buildings.defence_bonus(sys)

	-- A garrison defends; it does not besiege. So a captain standing on a system
	-- contributes to the *fleet* half only, and a world with nobody on it has no
	-- fleet half at all.
	local fleet, garrison = 0, {}
	for i = 1, #state.captains do
		local c = state.captains[i]
		if c.owner == owner and c.at == id then
			local held = commanders.power(c, mods[owner], units.FLEET)
			fleet = fleet + held
			garrison[#garrison + 1] = {
				captain = c.id, name = c.name,
				rank = commanders.rank(c.level or 1), power = held,
			}
		end
	end
	return fortification, fleet, garrison
end

--- Grind a battle out, exchange by exchange, and take what it cost.
--
-- **The outcome is already decided** by the two comparisons above - the player
-- did that arithmetic on the sheet before committing. This settles the other
-- half: what the captain has left afterwards, and the beats a replay is built
-- from.
--
-- Losses follow Lanchester's linear law. Two forces grinding each other in
-- proportion leave the winner having lost `D*D/A`, which for `A > D` is always
-- less than `D` and therefore always less than `A` - so a fight the sheet said
-- was winnable is one the captain survives. That is not a coincidence to be
-- checked, it is why this formula and not another.
--
-- Each half is fought separately, because each is answered by a different part
-- of the army: siege power against the walls, fleet power against whoever is
-- standing on them. A well-composed army finishes both sooner and pays less.
--
-- An **exchange** is a trade of damage inside a single turn. It is not a turn:
-- the whole battle is over before the turn that started it finishes.
local function fight(captain, siege, fortification, fleet_power, fleet)
	local function toll(attack, defence)
		if defence <= 0 or attack <= 0 then return 0 end
		return floor(defence * defence / attack)
	end

	local cost = toll(siege, fortification) + toll(fleet_power, fleet)
	-- How drawn out it was: an even fight goes the distance, an overwhelming
	-- one is over in a couple of exchanges.
	local total_defence = fortification + fleet
	local total_attack = siege + fleet_power
	local count = 1
	if total_attack > 0 and total_defence > 0 then
		count = floor(total_defence * rules.exchange_depth / total_attack) + 1
	end
	if count < 1 then count = 1 end
	if count > rules.max_exchanges then count = rules.max_exchanges end

	-- The officer's own command absorbs its share before the hold does, every
	-- exchange - which is why a veteran comes out of the same fight stronger.
	local shield = commanders.shield(captain) * count
	cost = cost - shield
	if cost < 0 then cost = 0 end

	local carried = commanders.carried(captain)
	if cost > carried then cost = carried end

	-- Spread across the exchanges, remainder to the first: a battle reads worst
	-- at the start, which is when the line is doing its job.
	local exchanges, lost = {}, units.empty()
	local left = cost
	for e = 1, count do
		local share = floor(left / (count - e + 1))
		if e == 1 then share = left - floor(left * (count - 1) / count) end
		if share > left then share = left end
		left = left - share
		local removed = units.strip(captain.units, share)
		local line = {}
		for k = 1, #units.CATALOGUE do
			local id = units.CATALOGUE[k].id
			lost[id] = lost[id] + removed[id]
			if removed[id] > 0 then line[id] = removed[id] end
		end
		exchanges[e] = { lost = line, shield = commanders.shield(captain) }
	end
	return exchanges, lost
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
			-- Nil, not zero: the officer survived and reforms with their own
			-- command. Everything they were carrying is gone, which is cost
			-- enough - leaving them at nothing would make a single lost battle
			-- unrecoverable for a player who cannot afford to re-arm.
			c.strength = nil
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
				local fortification, fleet, garrison =
					resistance(galaxy, state, mods, next_id)
				local siege = commanders.power(captain, my_mods, units.FORTIFICATION)
				local against_fleet = commanders.power(captain, my_mods, units.FLEET)

				-- **Two comparisons, and both must hold.** Siege power against
				-- the walls, fleet power against whoever is standing on them.
				-- Failing either stops the captain *before* the border, exactly
				-- as it did when there was one number: a border you cannot
				-- cross is one you do not stand in, and the route is dropped
				-- rather than held so nobody waits on something that may never
				-- change.
				if siege < fortification or against_fleet < fleet then
					captain.route = {}
					emit(events, {
						kind = "captain_blocked", turn = state.turn,
						player = captain.owner, captain = captain.id,
						name = captain.name, at = captain.at,
						blocked_by = next_id, held_by = defender,
						siege = siege, fortification = fortification,
						fleet_power = against_fleet, fleet = fleet,
						garrison = garrison,
						visible_to = { captain.owner },
					})
					break
				end

				-- Taken. The garrison goes home before the system changes
				-- hands, so `refuge` is asked while the defender still holds
				-- their capital - which matters when the capital *is* the
				-- system falling.
				break_defenders(state, mods, next_id, defender, events)
				-- The stock scatters rather than changing hands: units raised
				-- for one empire do not serve the next, and a colony that
				-- handed its conqueror an instant army would make taking one
				-- pay for itself twice over.
				sys.stock = 0

				local exchanges, lost = fight(captain, siege, fortification,
					against_fleet, fleet)

				-- Promotion is reported when the *title* changes, not when the
				-- level does. Ranks span two levels each, so awarding a level
				-- announced "promoted to Captain" to someone who was already
				-- a Captain - which reads as the game not knowing what it did.
				local was_rank = commanders.rank(captain.level or 1)
				commanders.award(captain, fortification + fleet)
				local now_rank = commanders.rank(captain.level or 1)
				sys.owner = captain.owner
				emit(events, {
					kind = "battle", turn = state.turn,
					at = next_id, player = captain.owner, captain = captain.id,
					name = captain.name, against = defender,
					rank = now_rank, level = captain.level,
					-- What was faced, what was brought, and what it cost -
					-- exchange by exchange, because a battle that reports only
					-- its outcome can be listed but never watched.
					fortification = fortification, fleet = fleet,
					siege = siege, fleet_power = against_fleet,
					garrison = garrison,
					exchanges = exchanges, lost = lost,
					-- **A copy, taken now.** `captain.units` is the live table:
					-- the captain goes on to march, and may load at a colony,
					-- before the turn is serialised - so the event recorded
					-- whatever the hold ended the *turn* with rather than what
					-- came out of the fight, and the battle screen unwound its
					-- exchanges from the wrong end.
					hold = units.normalise(captain.units),
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
				rank = commanders.rank(captain.level or 1),
				path = walked, bound_for = captain.route[#captain.route],
				visible_to = { captain.owner },
			})
		end
	end
end

--- Raise buildings and officers, in the order they were asked for.
--
-- **After movement, like everything else in logistics**, so a colony taken this
-- turn can be built on this turn - and so a build on a colony *lost* this turn
-- is refused rather than quietly enriching whoever took it.
--
-- Everything is checked here rather than in the RPC, because every condition it
-- turns on can move between the order being written and the turn resolving:
-- somebody else may hold the colony by then, the slots may be full, and the
-- purse has been spent on units in the meantime.
local function construction(galaxy, state, pending, events)
	for i = 1, #pending do
		local order = pending[i]
		local player = state.players[order.player]
		local sys = state.systems[order.at]

		local function reject(reason)
			emit(events, {
				kind = "order_rejected", turn = state.turn,
				player = order.player, at = order.at, reason = reason,
				visible_to = { order.player },
			})
		end

		if not sys or sys.owner ~= order.player then
			reject("not yours to build on")

		elseif order.recruit then
			local here = buildings.has(sys, "admiralty")
			local room = #state_mod.captains_of(state, order.player)
				< buildings.captain_cap(state, order.player)
			if not here then
				reject("no admiralty there")
			elseif not room then
				reject("no room for another captain")
			elseif (player.supply or 0) < rules.captain_cost then
				reject("not enough supply")
			else
				player.supply = player.supply - rules.captain_cost
				local captain = state_mod.add_captain(state, order.player, order.at)
				emit(events, {
					kind = "recruited", turn = state.turn,
					player = order.player, at = order.at,
					captain = captain.id, name = captain.name,
					cost = rules.captain_cost,
					visible_to = { order.player },
				})
			end

		else
			local spec = buildings.by_id(order.building)
			if not systems_mod.is_colony(galaxy, order.at) then
				reject("only a colony can be built on")
			elseif buildings.has(sys, order.building) then
				reject("already built")
			elseif not buildings.room(sys) then
				reject("no room for another building")
			elseif (player.supply or 0) < spec.cost then
				reject("not enough supply")
			else
				player.supply = player.supply - spec.cost
				sys.buildings[#sys.buildings + 1] = order.building
				emit(events, {
					kind = "built", turn = state.turn,
					player = order.player, at = order.at,
					building = order.building, name = spec.name,
					cost = spec.cost,
					visible_to = { order.player },
				})
			end
		end
	end
end

--- Buy the units a captain asked for, wherever it ended up.
--
-- **Where it ends the turn, not where it started.** A captain that marches onto
-- one of its own colonies resupplies the same turn, which is what makes a trip
-- home a single order rather than two turns of waiting. Movement is discrete
-- and the route is drawn before it is sent, so the player knows exactly where
-- the captain will be standing.
--
-- Everything is clamped rather than refused: what the colony has, what the
-- purse can pay for, and what the captain can still carry. A player asking for
-- six and getting four has been given the four, which is what they wanted; the
-- event says what actually happened.
local function logistics(galaxy, state, mods, events)
	for i = 1, #state.captains do
		local captain = state.captains[i]
		local want = captain.buying
		captain.buying = nil
		if want and units.count(want) > 0 then
			local player = state.players[captain.owner]
			local sys = state.systems[captain.at]
			local my_mods = mods[captain.owner]

			if sys.owner ~= captain.owner then
				emit(events, {
					kind = "order_rejected", turn = state.turn,
					player = captain.owner, captain = captain.id,
					reason = "not your colony", visible_to = { captain.owner },
				})
			else
				-- Clamped rather than refused, and in catalogue order so a
				-- player who asked for more than the berth, the purse or the
				-- hold allows gets as much of the front of their list as fits.
				-- The event says what actually came aboard.
				local room = commanders.room(captain, my_mods)
				local berths = sys.stock or 0
				local purse = player.supply or 0
				local taken, spent = units.empty(), 0
				for k = 1, #units.CATALOGUE do
					local spec = units.CATALOGUE[k]
					local n = want[spec.id] or 0
					if n > room then n = room end
					if n > berths then n = berths end
					local afford = floor((purse - spent) / spec.cost)
					if n > afford then n = afford end
					if n > 0 then
						taken[spec.id] = n
						room = room - n
						berths = berths - n
						spent = spent + n * spec.cost
					end
				end

				local count = units.count(taken)
				if count <= 0 then
					emit(events, {
						kind = "order_rejected", turn = state.turn,
						player = captain.owner, captain = captain.id,
						reason = (sys.stock or 0) == 0 and "nothing in stock"
							or (commanders.room(captain, my_mods) <= 0
								and "no room aboard" or "not enough supply"),
						visible_to = { captain.owner },
					})
				else
					for k = 1, #units.CATALOGUE do
						local id = units.CATALOGUE[k].id
						captain.units[id] = (captain.units[id] or 0) + taken[id]
					end
					sys.stock = sys.stock - count
					player.supply = purse - spent
					emit(events, {
						kind = "resupplied", turn = state.turn,
						player = captain.owner, captain = captain.id,
						name = captain.name, at = captain.at,
						units = count, took = taken, cost = spent,
						siege = commanders.power(captain, my_mods, units.FORTIFICATION),
						fleet_power = commanders.power(captain, my_mods, units.FLEET),
						visible_to = { captain.owner },
					})
				end
			end
		end
	end
end

--- What every system paid its owner, and what every colony made ready.
--
-- Stock accrues on a fixed cadence rather than per colony, so a player can read
-- "another unit every other turn" off the rules instead of tracking a timer per
-- world. It accumulates whether or not anyone visits and does not decay: a
-- distant colony is not wasted production, it is a reason to march.
local function economy(galaxy, state, summaries)
	local earned = {}
	for id, sys in pairs(state.systems) do
		if sys.owner ~= 0 then
			-- The capital's bonus goes to whoever is sitting in their own
			-- seat, which `capital_of` already says - no second lookup, and no
			-- way for a captured seat to keep paying its former owner.
			earned[sys.owner] = (earned[sys.owner] or 0)
				+ systems_mod.yield(galaxy, id, sys.capital_of == sys.owner)
			-- Cadence and cap are the colony's own, not the rules': Works makes
			-- one ready every turn and Yards holds more of them.
			if systems_mod.is_colony(galaxy, id)
				and (state.turn % buildings.stock_turns(sys)) == 0
				and (sys.stock or 0) < buildings.stock_cap(sys) then
				sys.stock = (sys.stock or 0) + 1
			end
		end
	end
	for i = 1, #state.players do
		local gained = earned[i] or 0
		state.players[i].supply = (state.players[i].supply or 0) + gained
		local s = summaries[i]
		if s then
			s.supply = state.players[i].supply
			s.earned = gained
		end
	end
end

-- 3. Aftermath ------------------------------------------------------------------

local function aftermath(galaxy, state, mods, events, summaries)
	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			-- **Their empire collapses with them.** A dead player used to keep
			-- every system they held, for ever: they never took another turn,
			-- but their borders still stood and their regions still counted, so
			-- everyone else was permanently locked out of a quarter of the map
			-- and no game could reach the victory threshold again. Every long
			-- game froze exactly this way.
			--
			-- The ground goes back to unclaimed rather than to the conqueror,
			-- because it was never taken - and an empire falling open is what
			-- gives the survivors somewhere to go next.
			local released = 0
			for _, sys in pairs(state.systems) do
				if sys.owner == i then
					sys.owner = 0
					sys.stock = 0
					sys.capital_of = 0
					released = released + 1
				end
			end
			for k = #state.captains, 1, -1 do
				if state.captains[k].owner == i then
					table.remove(state.captains, k)
				end
			end
			emit(events, {
				kind = "eliminated", turn = state.turn, player = i,
				released = released,
			})
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
	return visible
end

--- What each player saw of somebody else's movement.
--
-- `captain_moved` is the owner's own record and stays private, because it names
-- the officer and runs the whole way. A rival's movement is a **sighting**: as
-- much of the journey as fell inside your detection range and no more, so a
-- fleet crosses your border, is watched for a lane or two, and is lost again in
-- the dark. Anything else would either hide an invasion that was in plain sight
-- or hand over a campaign nobody could see.
--
-- Two simplifications, both deliberate:
--
--   * **End-of-turn visibility**, the same set every other event is filtered
--     against. Recomputing detection after each step would be more exact and
--     would disagree with every other event in the same digest.
--   * **The first contiguous run only.** A captain crosses at most three lanes
--     in a turn, so leaving and re-entering the same player's range inside one
--     turn needs a geometry that barely occurs; splitting a sighting into two
--     would cost an event to describe something nobody would notice.
--
-- A single visible point is not a sighting - that is a contact standing still,
-- and `view.project` already reports where rival captains are.
local function sighted_movement(state, events, visible)
	local sightings = {}
	for e = 1, #events do
		local ev = events[e]
		if ev.kind == "captain_moved" then
			local journey = { ev.from }
			for k = 1, #ev.path do journey[#journey + 1] = ev.path[k] end

			for p = 1, #state.players do
				if p ~= ev.player then
					local seen = visible[p]
					local first, last = nil, nil
					for k = 1, #journey do
						if seen[journey[k]] then
							if not first then first = k end
							last = k
						elseif first then
							break
						end
					end
					if first and last > first then
						local path = {}
						for k = first + 1, last do path[#path + 1] = journey[k] end
						sightings[#sightings + 1] = {
							kind = "contact_moved", turn = ev.turn,
							-- `player` is who it belongs to, as everywhere else;
							-- `visible_to` is the single player who saw it.
							player = ev.player, captain = ev.captain,
							rank = ev.rank, from = journey[first],
							path = path, at = journey[last],
							visible_to = { p },
						}
					end
				end
			end
		end
	end
	for i = 1, #sightings do events[#events + 1] = sightings[i] end
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
		summaries[i] = { claimed = 0, taken = 0, supply = 0, earned = 0 }
		mods[i] = modifiers.of(state.players[i])
	end

	-- Orders that spend rather than move are gathered here and settled in the
	-- logistics phase, so they see the map as it ends the turn.
	local pending = {}
	captain_orders(galaxy, state, orders, mods, lengths, events, pending)
	movement(galaxy, state, mods, events)
	-- After movement, because a captain buys where it *ends* the turn.
	construction(galaxy, state, pending, events)
	logistics(galaxy, state, mods, events)
	economy(galaxy, state, summaries)

	for e = 1, #events do
		local kind = events[e].kind
		local s = summaries[events[e].player]
		if s then
			if kind == "claimed" then s.claimed = s.claimed + 1
			elseif kind == "battle" then s.taken = s.taken + 1 end
		end
	end

	aftermath(galaxy, state, mods, events, summaries)
	local visible = apply_visibility(galaxy, state, events)
	sighted_movement(state, events, visible)

	return events
end

return M
