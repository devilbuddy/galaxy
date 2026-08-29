--- One turn of the simulation.
--
-- `M.turn(realm, state, orders)` advances exactly one turn and
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
-- built back, as one comparison. Commanders move along tiles, claim what they
-- pass through, and take ground off each other when they have the strength to.
--
-- Two invariants survive from the version this replaced, and both must:
--
--   * **Never iterate a hash table with `pairs` where the order affects the
--     output.** Lua's `pairs` order is unspecified, and the server and client
--     have to agree exactly.
--   * **Every event carries who may see it** (`visible_to`), applied at the end
--     against what each player can actually observe.

local rng = require("realm.rng")
local rules = require("realm.sim.rules")
local state_mod = require("realm.sim.state")
local path_mod = require("realm.sim.path")
local view = require("realm.sim.view")
local commanders = require("realm.sim.commanders")
local provinces_mod = require("realm.sim.provinces")
local modifiers = require("realm.sim.modifiers")
local tiles_mod = require("realm.sim.tiles")
local buildings = require("realm.sim.buildings")
local units = require("realm.sim.units")

local floor = math.floor
local min = math.min

local M = {}

local function emit(events, e)
	events[#events + 1] = e
	return e
end

-- 1. Orders ---------------------------------------------------------------------

--- Expand a list of wilds into the tile-by-tile route a commander will fly.
--
-- Exported because the client draws the route the moment an order is issued,
-- and a preview computed by a different implementation is a preview that can
-- lie. There is one function, and the server runs it for both purposes - see
-- `game.route` in server/modules/game_rpc.lua.
function M.expand_route(realm, from, fixed, wilds, hops_allowed)
	local route, hops = {}, 0
	-- A commander already in a tile must finish it before turning, so the current
	-- leg is fixed and everything is plotted from its far end.
	if fixed then
		route[1] = fixed
		from = fixed
		hops = 1
	end
	for w = 1, #wilds do
		local to = floor(wilds[w])
		if to ~= from then
			local leg = path_mod.find(realm, from, to, hops_allowed - hops)
			if not leg or #leg == 0 then return nil, "no route" end
			for h = 1, #leg do route[#route + 1] = leg[h] end
			hops = hops + #leg
			from = to
		end
	end
	return route
end

local expand_route = M.expand_route

--- Give commanders their orders. There is one verb: move.
--
-- Invalid orders are dropped with a reason rather than silently ignored, so the
-- client can say what happened. Whether an order is *legal* depends on state
-- that has moved on since the player issued it, which is why the check is here
-- and not in the RPC.
local function commander_orders(realm, state, orders, mods, events, pending)
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
			-- tile, what is already there, whether the purse can pay - may
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

		elseif order.kind == "buy" then
			-- **Buying belongs to the city, not to a commander.** What is
			-- bought goes into the garrison and waits there, so a player spends
			-- the turn they have the money and collects whenever somebody can
			-- get to it. Before this, arming required an officer standing on
			-- the spot at the moment of purchase - which with three dwellings
			-- in three places is three tours to synchronise with a purse.
			--
			-- Recorded rather than acted on, like a build: who holds the
			-- city can change in the movement phase that has not run yet.
			local at = order.at and floor(order.at)
			if at then
				pending[#pending + 1] = {
					player = who, at = at, buy = units.normalise(order.units),
				}
			else
				reject("nowhere to buy")
			end

		elseif order.kind == "transfer" then
			-- **A commander rearranging what is already yours**, at a place it is
			-- already standing. It costs no order at all - see
			-- `rules.order_cost` - and it is a *target hold*, not a delta: the
			-- client sets what should be aboard when the turn is over and the
			-- resolver moves whatever it takes to get there, in either
			-- direction. A delta would be wrong the moment anything else
			-- touched either side first.
			local commander = state_mod.commander_by_id(state, order.commander)
			if not commander or commander.owner ~= who then
				reject("no such commander", { commander = order.commander })
			else
				-- Recorded rather than acted on: a commander transfers where it
				-- *ends* the turn, so a march onto one of your cities and a
				-- swap there are one turn's work.
				commander.swapping = units.normalise(order.units)
			end

		elseif order.kind == "move" then
			local commander = state_mod.commander_by_id(state, order.commander)
			if not commander or commander.owner ~= who then
				reject("no such commander", { commander = order.commander })
			else
				local wilds = order.route
				if type(wilds) ~= "table" or #wilds == 0 then
					-- An empty route is how a commander is told to stand still.
					commander.route = {}
				else
					local fixed = state_mod.next_hop(commander)
					local from = fixed or commander.at
					local route, why = expand_route(realm, from,
						fixed, wilds, m.hops)
					if not route or #route == 0 then
						reject(why or "no route", {
							commander = commander.id, to = wilds[#wilds],
						})
					else
						commander.route = route
						emit(events, {
							kind = "commander_ordered", turn = state.turn,
							player = who, commander = commander.id, name = commander.name,
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
-- data, whose seat it is is in their view, and a commander standing on it is a
-- contact they have eyes on. That is what makes the comparison below a decision
-- rather than a gamble.
--
-- **Two halves, both public, and an army is aimed at one or the other.** The
-- world's own fortification is derived from the tile and whatever has been
-- built on it; the army is whoever is standing there. Returns them separately
-- because they are separately compared, and the garrison by name because a
-- fight that reports only numbers can never be replayed as anything more than
-- numbers.
local function resistance(realm, state, mods, id)
	local sys = state.tiles[id]
	local owner = sys.owner
	local fortification = tiles_mod.defence(realm, id, sys.seat_of == owner,
		mods[owner]) + buildings.defence_bonus(sys)

	-- A defender defends; it does not besiege. So everything standing on a
	-- tile contributes to the *army* half only, and a world with nothing on
	-- it has no army half at all.
	--
	-- Two things stand: the city's own garrison, and any commander of the
	-- owner's who happens to be there.
	--
	-- **The garrison defends because it was bought.** Production used to defend
	-- the world holding it, and that had to be taken out - defence accumulated
	-- for free while an attacker carried theirs across the realm, and the map
	-- froze. A garrison is not that. Every unit standing on a world is a unit
	-- that is not in a commander's hold, so a player who fortifies pays for it in
	-- offence and the trade balances itself.
	local army, garrison = 0, {}
	local held_here = units.power(sys.garrison, units.ARMY)
	if held_here > 0 then
		army = army + held_here
		garrison[#garrison + 1] = {
			name = "Garrison", power = held_here,
			hold = units.normalise(sys.garrison),
		}
	end
	for i = 1, #state.commanders do
		local c = state.commanders[i]
		if c.owner == owner and c.at == id then
			local held = commanders.power(c, mods[owner], units.ARMY)
			army = army + held
			garrison[#garrison + 1] = {
				commander = c.id, name = c.name,
				rank = commanders.rank(c.level or 1), power = held,
			}
		end
	end
	return fortification, army, garrison
end

--- Grind a battle out, exchange by exchange, and take what it cost.
--
-- **The outcome is already decided** by the two comparisons above - the player
-- did that arithmetic on the sheet before committing. This settles the other
-- half: what the commander has left afterwards, and the beats a replay is built
-- from.
--
-- Losses follow Lanchester's linear law. Two forces grinding each other in
-- proportion leave the winner having lost `D*D/A`, which for `A > D` is always
-- less than `D` and therefore always less than `A` - so a fight the sheet said
-- was winnable is one the commander survives. That is not a coincidence to be
-- checked, it is why this formula and not another.
--
-- Each half is fought separately, because each is answered by a different part
-- of the army: siege power against the walls, army power against whoever is
-- standing on them. A well-composed army finishes both sooner and pays less.
--
-- An **exchange** is a trade of damage inside a single turn. It is not a turn:
-- the whole battle is over before the turn that started it finishes.
local function fight(commander, siege, fortification, army_power, army)
	local function toll(attack, defence)
		if defence <= 0 or attack <= 0 then return 0 end
		return floor(defence * defence / attack)
	end

	local cost = toll(siege, fortification) + toll(army_power, army)
	-- How drawn out it was: an even fight goes the distance, an overwhelming
	-- one is over in a couple of exchanges.
	local total_defence = fortification + army
	local total_attack = siege + army_power
	local count = 1
	if total_attack > 0 and total_defence > 0 then
		count = floor(total_defence * rules.exchange_depth / total_attack) + 1
	end
	if count < 1 then count = 1 end
	if count > rules.max_exchanges then count = rules.max_exchanges end

	-- The officer's own command absorbs its share before the hold does, every
	-- exchange - which is why a veteran comes out of the same fight stronger.
	local shield = commanders.shield(commander) * count
	cost = cost - shield
	if cost < 0 then cost = 0 end

	local carried = commanders.carried(commander)
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
		local removed = units.strip(commander.units, share)
		local line = {}
		for k = 1, #units.CATALOGUE do
			local id = units.CATALOGUE[k].id
			lost[id] = lost[id] + removed[id]
			if removed[id] > 0 then line[id] = removed[id] end
		end
		exchanges[e] = { lost = line, shield = commanders.shield(commander) }
	end
	return exchanges, lost
end

--- Throw the defenders of a tile that has just fallen back to their seat.
--
-- Broken rather than killed, and demoted rather than deleted: with one commander
-- each, an officer who could be removed from the board would end the game for
-- their player on a single bad turn, and everyone would stop committing.
local function break_defenders(state, mods, id, owner, events)
	-- **The garrison was the fight, so the garrison is gone.** It stood in the
	-- army half of the comparison the attacker had to beat, and a defence that
	-- survived losing would mean an attacker paying for the same wall twice.
	local sys = state.tiles[id]
	if sys and units.count(sys.garrison) > 0 then
		emit(events, {
			kind = "garrison_lost", turn = state.turn,
			player = owner, at = id, lost = units.normalise(sys.garrison),
			units = units.count(sys.garrison), visible_to = { owner },
		})
		sys.garrison = units.empty()
	end
	for i = 1, #state.commanders do
		local c = state.commanders[i]
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
				kind = "commander_broken", turn = state.turn,
				player = owner, commander = c.id, name = c.name,
				at = home, lost = id, rank = commanders.rank(c.level),
				visible_to = { owner },
			})
		end
	end
end

--- Move every commander as far as its turn allows, claiming and taking as it goes.
--
-- A commander crosses a whole number of tiles and always ends the turn *at* a
-- tile. Movement used to be a distance covered along a tile, which meant a
-- commander could sit partway down one - a state the player could neither see at
-- fit zoom nor predict, because it is not drawn.
--
-- Unclaimed tiles are taken in passing and do not stop it, so a route through
-- a chain of empty tiles sweeps them all up.
--
-- **A commander attacks only when it can win.** If it cannot cover the
-- resistance it stops at the border exactly as it did before combat existed,
-- and the event says both numbers so the player can see what it would take. The
-- alternative - letting an assault fail - would mean a commander could be spent
-- to nothing by an arithmetic slip made twelve hours earlier, and would turn
-- every attack into a gamble in a game whose whole point is planning ahead.
local function movement(realm, state, mods, events)
	for i = 1, #state.commanders do
		local commander = state.commanders[i]
		local my_mods = mods[commander.owner]
		local steps = commanders.steps(commander, my_mods)
		-- Where it started, and every tile it sets foot in. Nothing in the
		-- resolver reads this back; it exists because **the event log is the
		-- record of the turn**, and a log that reports only outcomes can be
		-- listed but never replayed. A commander crossing its own territory
		-- changes nothing and so emitted nothing at all, which meant the one
		-- thing a player would most want to watch - an army moving - was the
		-- one thing the log did not contain.
		local from, walked = commander.at, {}

		while steps > 0 and #commander.route > 0 do
			local next_id = commander.route[1]
			local sys = state.tiles[next_id]
			local defender = sys.owner

			if defender ~= 0 and defender ~= commander.owner then
				local fortification, army, garrison =
					resistance(realm, state, mods, next_id)
				local siege = commanders.power(commander, my_mods, units.FORTIFICATION)
				local against_army = commanders.power(commander, my_mods, units.ARMY)

				-- **Two comparisons, and both must hold.** Siege power against
				-- the walls, army power against whoever is standing on them.
				-- Failing either stops the commander *before* the border, exactly
				-- as it did when there was one number: a border you cannot
				-- cross is one you do not stand in, and the route is dropped
				-- rather than held so nobody waits on something that may never
				-- change.
				if siege < fortification or against_army < army then
					commander.route = {}
					emit(events, {
						kind = "commander_blocked", turn = state.turn,
						player = commander.owner, commander = commander.id,
						name = commander.name, at = commander.at,
						blocked_by = next_id, held_by = defender,
						siege = siege, fortification = fortification,
						army_power = against_army, army = army,
						garrison = garrison,
						visible_to = { commander.owner },
					})
					break
				end

				-- Taken. The garrison goes home before the tile changes
				-- hands, so `refuge` is asked while the defender still holds
				-- their seat - which matters when the seat *is* the
				-- tile falling.
				break_defenders(state, mods, next_id, defender, events)
				-- **What was ready scatters; what was built stands.** Units
				-- raised for one empire do not serve the next, and a city
				-- that handed its conqueror an instant army would pay for
				-- taking it twice over. The dwellings that made them are a
				-- different matter - they live on the tile, so a developed
				-- city changes hands intact, and that is what makes somebody
				-- else's arsenal worth marching on.
				--
				-- The garrison is not cleared here: it stood in the fight, and
				-- `break_defenders` has already taken it apart.
				sys.available = units.empty()

				local exchanges, lost = fight(commander, siege, fortification,
					against_army, army)

				-- Promotion is reported when the *title* changes, not when the
				-- level does. Ranks span two levels each, so awarding a level
				-- announced "promoted to Commander" to someone who was already
				-- a Commander - which reads as the game not knowing what it did.
				local was_rank = commanders.rank(commander.level or 1)
				commanders.award(commander, fortification + army)
				local now_rank = commanders.rank(commander.level or 1)
				sys.owner = commander.owner
				emit(events, {
					kind = "battle", turn = state.turn,
					at = next_id, player = commander.owner, commander = commander.id,
					name = commander.name, against = defender,
					rank = now_rank, level = commander.level,
					-- What was faced, what was brought, and what it cost -
					-- exchange by exchange, because a battle that reports only
					-- its outcome can be listed but never watched.
					fortification = fortification, army = army,
					siege = siege, army_power = against_army,
					garrison = garrison,
					exchanges = exchanges, lost = lost,
					-- **A copy, taken now.** `commander.units` is the live table:
					-- the commander goes on to march, and may load at a city,
					-- before the turn is serialised - so the event recorded
					-- whatever the hold ended the *turn* with rather than what
					-- came out of the fight, and the battle screen unwound its
					-- exchanges from the wrong end.
					hold = units.normalise(commander.units),
					promoted = (now_rank ~= was_rank) and now_rank or nil,
				})
			end

			commander.at = next_id
			walked[#walked + 1] = next_id
			table.remove(commander.route, 1)
			steps = steps - 1

			if sys.owner == 0 then
				sys.owner = commander.owner
				emit(events, {
					kind = "claimed", turn = state.turn,
					at = next_id, player = commander.owner,
					commander = commander.id, name = commander.name,
				})
			end
		end

		if #walked > 0 then
			emit(events, {
				kind = "commander_moved", turn = state.turn,
				player = commander.owner, commander = commander.id,
				name = commander.name, from = from, at = commander.at,
				rank = commanders.rank(commander.level or 1),
				path = walked, bound_for = commander.route[#commander.route],
				visible_to = { commander.owner },
			})
		end
	end
end

--- Raise buildings and officers, in the order they were asked for.
--
-- **After movement, like everything else in logistics**, so a city taken this
-- turn can be built on this turn - and so a build on a city *lost* this turn
-- is refused rather than quietly enriching whoever took it.
--
-- Everything is checked here rather than in the RPC, because every condition it
-- turns on can move between the order being written and the turn resolving:
-- somebody else may hold the city by then, the slots may be full, and the
-- purse has been spent on units in the meantime.
local function construction(realm, state, pending, events)
	for i = 1, #pending do
		local order = pending[i]
		local player = state.players[order.player]
		local sys = state.tiles[order.at]

		local function reject(reason)
			emit(events, {
				kind = "order_rejected", turn = state.turn,
				player = order.player, at = order.at, reason = reason,
				visible_to = { order.player },
			})
		end

		if not sys or sys.owner ~= order.player then
			reject("not yours to build on")

		elseif order.buy then
			-- **Clamped rather than refused**, in catalogue order, against
			-- three things: what the dwellings have actually produced, what the
			-- purse can pay for, and what the city can still hold.
			--
			-- A player who asked for six and can afford four has been given the
			-- four, which is what they wanted; the event says what happened.
			local purse = player.gold or 0
			local room = rules.garrison_cap - units.count(sys.garrison)
			local taken, spent = units.empty(), 0
			for k = 1, #units.CATALOGUE do
				local spec = units.CATALOGUE[k]
				local n = order.buy[spec.id] or 0
				local ready = sys.available[spec.id] or 0
				if n > ready then n = ready end
				if n > room then n = room end
				local afford = floor((purse - spent) / spec.cost)
				if n > afford then n = afford end
				if n > 0 then
					taken[spec.id] = n
					room = room - n
					spent = spent + n * spec.cost
				end
			end

			local count = units.count(taken)
			if count <= 0 then
				reject(units.count(sys.available) == 0 and "nothing ready here"
					or (units.count(sys.garrison) >= rules.garrison_cap
						and "the garrison is full" or "not enough gold"))
			else
				for k = 1, #units.CATALOGUE do
					local id = units.CATALOGUE[k].id
					sys.available[id] = sys.available[id] - taken[id]
					sys.garrison[id] = (sys.garrison[id] or 0) + taken[id]
				end
				player.gold = purse - spent
				emit(events, {
					kind = "bought", turn = state.turn,
					player = order.player, at = order.at,
					units = count, took = taken, cost = spent,
					visible_to = { order.player },
				})
			end

		elseif order.recruit then
			local here = buildings.has(sys, "admiralty")
			local room = #state_mod.commanders_of(state, order.player)
				< buildings.commander_cap(state, order.player)
			if not here then
				reject("no admiralty there")
			elseif not room then
				reject("no room for another commander")
			elseif (player.gold or 0) < rules.commander_cost then
				reject("not enough gold")
			else
				player.gold = player.gold - rules.commander_cost
				local commander = state_mod.add_commander(state, order.player, order.at)
				emit(events, {
					kind = "recruited", turn = state.turn,
					player = order.player, at = order.at,
					commander = commander.id, name = commander.name,
					cost = rules.commander_cost,
					visible_to = { order.player },
				})
			end

		else
			local spec = buildings.by_id(order.building)
			if not tiles_mod.is_city(realm, order.at) then
				reject("only a city can be built on")
			elseif buildings.has(sys, order.building) then
				reject("already built")
			elseif not buildings.room(sys) then
				reject("no room for another building")
			elseif (player.gold or 0) < spec.cost then
				reject("not enough gold")
			else
				player.gold = player.gold - spec.cost
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

--- Move units between a city's garrison and the commander standing on it.
--
-- **Where it ends the turn, not where it started.** A commander that marches onto
-- one of its own cities swaps the same turn, which is what makes a trip home
-- a single order rather than two turns of waiting. Movement is discrete and the
-- route is drawn before it is sent, so the player knows exactly where the
-- commander will be standing.
--
-- **The order carries a target hold, not a delta.** Whatever the commander should
-- have aboard when the turn is over; the resolver works out which way each type
-- has to move and does it. A delta would be wrong the moment anything else
-- touched either side first - a battle on the way in, a purchase landing the
-- same turn - and this way the client only ever has to state the thing the
-- player actually chose.
--
-- Clamped rather than refused, in catalogue order: what the garrison can gold
-- and what the commander can still carry. A player who asked for six and got four
-- has been given the four.
local function transfers(realm, state, mods, events)
	for i = 1, #state.commanders do
		local commander = state.commanders[i]
		local want = commander.swapping
		commander.swapping = nil
		if want then
			local sys = state.tiles[commander.at]
			local my_mods = mods[commander.owner]

			if not sys or sys.owner ~= commander.owner then
				emit(events, {
					kind = "order_rejected", turn = state.turn,
					player = commander.owner, commander = commander.id,
					reason = "not your city", visible_to = { commander.owner },
				})
			else
				local capacity = commanders.max_units(commander, my_mods)
				local aboard, moved = 0, 0
				for k = 1, #units.CATALOGUE do
					local id = units.CATALOGUE[k].id
					local have = commander.units[id] or 0
					local here = sys.garrison[id] or 0
					local target = want[id] or 0

					-- Up, but only as far as the garrison and the hold allow.
					if target > have + here then target = have + here end
					if target > have + (capacity - aboard - have) then
						target = have + (capacity - aboard - have)
					end
					if target < 0 then target = 0 end

					local delta = target - have
					commander.units[id] = have + delta
					sys.garrison[id] = here - delta
					aboard = aboard + commander.units[id]
					moved = moved + (delta < 0 and -delta or delta)
				end

				if moved > 0 then
					emit(events, {
						kind = "transferred", turn = state.turn,
						player = commander.owner, commander = commander.id,
						name = commander.name, at = commander.at,
						units = moved,
						hold = units.normalise(commander.units),
						siege = commanders.power(commander, my_mods, units.FORTIFICATION),
						army_power = commanders.power(commander, my_mods, units.ARMY),
						visible_to = { commander.owner },
					})
				end
			end
		end
	end
end

--- What every tile paid its owner, and what every dwelling made ready.
--
-- **A city makes only what it has dwellings for.** Each carries its own cap
-- and its own cadence, so a Foundry fills slowly and Berths quickly, and a
-- world with neither fills not at all. Availability accumulates whether or not
-- anyone visits and does not decay: a distant city is not wasted production,
-- it is a reason to march.
local function economy(realm, state, summaries)
	local earned = {}
	for id, sys in pairs(state.tiles) do
		if sys.owner ~= 0 then
			-- The seat's bonus goes to whoever is sitting in their own
			-- seat, which `seat_of` already says - no second lookup, and no
			-- way for a captured seat to keep paying its former owner.
			earned[sys.owner] = (earned[sys.owner] or 0)
				+ tiles_mod.yield(realm, id, sys.seat_of == sys.owner)
			-- One pass per dwelling standing here. Catalogue order, never
			-- `pairs`, because two runtimes have to agree on what a turn did.
			local dwellings = buildings.dwellings(sys)
			for d = 1, #dwellings do
				local spec = dwellings[d]
				local made = spec.makes
				if (state.turn % spec.every) == 0
					and (sys.available[made] or 0) < spec.ready then
					sys.available[made] = (sys.available[made] or 0) + 1
				end
			end
		end
	end
	for i = 1, #state.players do
		local gained = earned[i] or 0
		state.players[i].gold = (state.players[i].gold or 0) + gained
		local s = summaries[i]
		if s then
			s.gold = state.players[i].gold
			s.earned = gained
		end
	end
end

-- 3. Aftermath ------------------------------------------------------------------

local function aftermath(realm, state, mods, events, summaries)
	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			-- **Their empire collapses with them.** A dead player used to keep
			-- every tile they held, for ever: they never took another turn,
			-- but their borders still stood and their provinces still counted, so
			-- everyone else was permanently locked out of a quarter of the map
			-- and no game could reach the victory threshold again. Every long
			-- game froze exactly this way.
			--
			-- The ground goes back to unclaimed rather than to the conqueror,
			-- because it was never taken - and an empire falling open is what
			-- gives the survivors somewhere to go next.
			local released = 0
			for _, sys in pairs(state.tiles) do
				if sys.owner == i then
					sys.owner = 0
					sys.available = units.empty()
					sys.garrison = units.empty()
					sys.seat_of = 0
					released = released + 1
				end
			end
			for k = #state.commanders, 1, -1 do
				if state.commanders[k].owner == i then
					table.remove(state.commanders, k)
				end
			end
			emit(events, {
				kind = "eliminated", turn = state.turn, player = i,
				released = released,
			})
		end
	end

	-- Province control, and with it the only way the game ends. Recomputed rather
	-- than tracked: it is a pure function of who owns what.
	local held = provinces_mod.control(realm, state)
	local previous = state.provinces_held or {}
	for r = 1, #held do
		if held[r] ~= (previous[r] or 0) then
			emit(events, {
				kind = "province_control", turn = state.turn, province = r,
				name = realm.provinces[r] and realm.provinces[r].name,
				player = held[r], from = previous[r] or 0,
			})
		end
	end
	state.provinces_held = held

	if not state.winner then
		local needed = provinces_mod.needed(realm)
		local tally = provinces_mod.tally(realm, state, held)
		for i = 1, #state.players do
			if (tally[i] or 0) >= needed and state.players[i].alive then
				state.winner = i
				emit(events, {
					kind = "victory", turn = state.turn, player = i,
					provinces = tally[i], needed = needed, by = "provinces",
				})
			end
		end

		-- The other way to win, which only became reachable when seats
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
					provinces = tally[last] or 0, needed = needed,
					by = "survival",
				})
			end
		end
	end

	for i = 1, #state.players do
		view.remember(realm, state, i)
	end

	-- A private end-of-turn digest per player: the backbone of "what happened
	-- while you were away".
	for i = 1, #state.players do
		local s = summaries[i]
		if s then
			s.kind = "turn_summary"
			s.turn = state.turn
			s.player = i
			s.tiles = state_mod.holdings_of(state, i)
			s.provinces = 0
			for r = 1, #state.provinces_held do
				if state.provinces_held[r] == i then s.provinces = s.provinces + 1 end
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
local function apply_visibility(realm, state, events)
	local visible = {}
	for i = 1, #state.players do
		visible[i] = view.visible_tiles(realm, state, i)
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
-- `commander_moved` is the owner's own record and stays private, because it names
-- the officer and runs the whole way. A rival's movement is a **sighting**: as
-- much of the journey as fell inside your detection range and no more, so a
-- army crosses your border, is watched for a tile or two, and is lost again in
-- the dark. Anything else would either hide an invasion that was in plain sight
-- or hand over a campaign nobody could see.
--
-- Two simplifications, both deliberate:
--
--   * **End-of-turn visibility**, the same set every other event is filtered
--     against. Recomputing detection after each step would be more exact and
--     would disagree with every other event in the same digest.
--   * **The first contiguous run only.** A commander crosses at most three tiles
--     in a turn, so leaving and re-entering the same player's range inside one
--     turn needs a geometry that barely occurs; splitting a sighting into two
--     would cost an event to describe something nobody would notice.
--
-- A single visible point is not a sighting - that is a contact standing still,
-- and `view.project` already reports where rival commanders are.
local function sighted_movement(state, events, visible)
	local sightings = {}
	for e = 1, #events do
		local ev = events[e]
		if ev.kind == "commander_moved" then
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
							player = ev.player, commander = ev.commander,
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

function M.turn(realm, state, orders)
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
		summaries[i] = { claimed = 0, taken = 0, gold = 0, earned = 0 }
		mods[i] = modifiers.of(state.players[i])
	end

	-- Orders that spend rather than move are gathered here and settled in the
	-- logistics phase, so they see the map as it ends the turn.
	local pending = {}
	commander_orders(realm, state, orders, mods, events, pending)
	movement(realm, state, mods, events)
	-- After movement, because everything here happens where the turn *ends*: a
	-- city taken this turn can be built on and bought from this turn, and a
	-- commander that marched home swaps there. Buying runs before transferring,
	-- so a purchase and a collection are one turn's work.
	construction(realm, state, pending, events)
	transfers(realm, state, mods, events)
	economy(realm, state, summaries)

	for e = 1, #events do
		local kind = events[e].kind
		local s = summaries[events[e].player]
		if s then
			if kind == "claimed" then s.claimed = s.claimed + 1
			elseif kind == "battle" then s.taken = s.taken + 1 end
		end
	end

	aftermath(realm, state, mods, events, summaries)
	local visible = apply_visibility(realm, state, events)
	sighted_movement(state, events, visible)

	return events
end

return M
