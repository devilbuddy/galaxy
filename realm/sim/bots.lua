--- What a bot does with its turn.
--
-- Engine-free, like the rest of `realm/sim`, so the same code decides a bot's
-- move on the Nakama server and in `tools/play.lua` under luajit. One
-- implementation means the AI a player faces is the AI that gets exercised in
-- the offline harness - two would drift, and the one nobody runs would be the
-- one shipping.
--
-- **Deterministic, like everything else here.** A bot never touches
-- `math.random`: its stream is derived from the game seed, the player and the
-- turn, so replaying a game reproduces the bots exactly, and a bot on a Nakama
-- restart makes the same choice it was going to make before.
--
-- This is deliberately a plain function rather than a behaviour tree. The game
-- has one verb - move a commander along a route - so the entire decision is
-- "which tile next", and a tree there is ceremony around an `if`. When a bot
-- has to weigh expanding against defending against raiding against building,
-- that is the moment to reach for one.
--
-- **It knows what a fight costs.** Combat is a single visible comparison, so a
-- bot can price a target exactly the way a player can, and it simply never
-- picks one it cannot afford. What it does not do yet is defend, retreat, or
-- wait deliberately for a promotion - it waits only because it has run out of
-- things it can pay for.

local rng = require("realm.rng")
local rules = require("realm.sim.rules")
local state_mod = require("realm.sim.state")
local tiles = require("realm.sim.tiles")
local commanders = require("realm.sim.commanders")
local modifiers = require("realm.sim.modifiers")
local buildings = require("realm.sim.buildings")
local units = require("realm.sim.units")

local M = {}

-- How a bot picks among equally-near targets: **by what the ground actually
-- pays it**. Not a table of its own - `tiles.yield` is the number, so a bot
-- values a place exactly the way the economy does and follows it automatically
-- when the economy is retuned.
--
-- It matters more than it did. Open country used to pay 1 a turn for ever, which
-- was a small but real reason to walk to one; it now pays nothing and is worth
-- taking only as passage - and passage is free, because the resolver claims
-- unclaimed ground *in passing* along a route. So a bot aimed at a city three
-- tiles off sweeps up the road on the way without ever having chosen it.
--
-- The seat bonus is deliberately not included: a bot cannot take a seat
-- and keep it paying, and pricing one as though it could would send commanders at
-- the one target they are least able to hold.

-- Taking something off somebody is worth more than walking into empty space -
-- it is the only thing that moves a border - but it costs strength that would
-- otherwise have bought two or three free tiles, so the premium is modest.
local CONTESTED_BONUS = 1.5

--- What it would cost this bot to take `id` from whoever holds it.
--
-- The same sum the resolver does, and deliberately so: a bot working from a
-- different estimate would march into fights it cannot win, which is the exact
-- mistake "never walk into a border" was written to stop.
local function cost_of(realm, state, mods, id)
	local sys = state.tiles[id]
	local owner = sys.owner
	local fortification = tiles.defence(realm, id, sys.seat_of == owner,
		mods[owner]) + buildings.defence_bonus(sys)
	local army = 0
	for i = 1, #state.commanders do
		local c = state.commanders[i]
		if c.owner == owner and c.at == id then
			army = army + commanders.power(c, mods[owner], units.ARMY)
		end
	end
	return fortification, army
end

--- Walk back up the search tree to the route that reaches `id`.
--
-- **The route matters, not just the destination.** A bot picks its target by
-- walking only through ground it already holds - but an order carries a
-- destination, and `resolve.expand_route` pathfinds it across the *whole*
-- graph, which will happily route through somebody else's space and be turned
-- back at the border. Naming every step as open country is what makes the order
-- take the path the bot actually reasoned about.
--
-- Truncated to what a commander is allowed to plot, so a depot on the far side of
-- an empire produces a march in its direction rather than "no route" - which is
-- what a hundred and twenty of these were.
local function route_to(parent, id, limit)
	local reversed = {}
	local at = id
	while at do
		reversed[#reversed + 1] = at
		at = parent[at]
	end
	local route = {}
	-- Drop the start, which the commander is already standing on.
	for i = #reversed - 1, 1, -1 do
		route[#route + 1] = reversed[i]
		if #route >= limit then break end
	end
	return route
end

--- The nearest tiles worth going to, reachable without crossing a border.
--
-- Breadth-first out from `from`, walking only through space this player already
-- holds - a commander that has to fight its way *to* a target has spent the
-- strength it was going to take the target with.
--
-- Two kinds of target: unclaimed ground, which is free, and a neighbour's
-- tile the commander can currently afford. Anything dearer than the strength in
-- hand is not a target at all, because the resolver would simply turn the
-- commander back at the border and the trip would be wasted.
local function reachable_targets(realm, state, mods, player, from,
	siege, army_power, limit)
	local dist = { [from] = 0 }
	local parent = {}
	local queue, head = { from }, 1
	local found = {}

	while head <= #queue and #found < limit do
		local id = queue[head]
		head = head + 1
		local neighbours = realm.adjacency[id]
		for k = 1, #neighbours do
			local n = neighbours[k]
			if not dist[n] then
				dist[n] = dist[id] + 1
				parent[n] = id
				local owner = state.tiles[n].owner
				if owner == 0 then
					found[#found + 1] = { id = n, hops = dist[n], cost = 0 }
				elseif owner == player then
					queue[#queue + 1] = n
				else
					-- **Both comparisons, the same two the sheet shows.** A bot
					-- working from a different sum would march into fights it
					-- cannot win, which is the exact mistake "never walk into a
					-- border" was written to stop.
					local fortification, army = cost_of(realm, state, mods, n)
					if siege >= fortification and army_power >= army then
						found[#found + 1] = {
							id = n, hops = dist[n],
							cost = fortification + army,
						}
					end
					-- Too dear: not a road either, so the search stops here.
				end
			end
		end
	end
	-- Every candidate carries the road the search took to reach it, because the
	-- destination alone is not enough - see route_to.
	for i = 1, #found do
		found[i].route = route_to(parent, found[i].id, rules.max_route_hops)
	end
	return found
end

--- The nearest city of this player's that has anything worth collecting.
--
-- Same walk as `reachable_targets`, through their own ground only - a commander
-- that has to fight its way to a depot arrives with nothing to put in it.
local function nearest_depot(realm, state, player, from)
	local parent = {}
	local seen = { [from] = true }
	local queue, head = { from }, 1
	while head <= #queue do
		local id = queue[head]
		head = head + 1
		local sys = state.tiles[id]
		-- Somewhere with something to pick up: either bought and waiting in
		-- the garrison, or ready to buy on arrival. Both are worth the trip,
		-- and buying costs no order so the second is not a worse errand.
		if sys.owner == player and id ~= from
			and (units.count(sys.garrison) > 0 or units.count(sys.available) > 0) then
			return id, route_to(parent, id, rules.max_route_hops)
		end
		local neighbours = realm.adjacency[id]
		for k = 1, #neighbours do
			local n = neighbours[k]
			if not seen[n] and state.tiles[n].owner == player then
				seen[n] = true
				parent[n] = id
				queue[#queue + 1] = n
			end
		end
	end
	return nil
end

--- Score a candidate. Near beats far, and something that pays beats rock.
local function score(realm, candidate, jitter)
	return tiles.yield(realm, candidate.id)
		+ (candidate.cost > 0 and CONTESTED_BONUS or 0)
		- candidate.hops * 1.5
		+ jitter
end

-- Kept back so a bot never builds itself out of an army. Two units is enough to
-- top a commander up on the next city it reaches.
local RESERVE_UNITS = 2

--- Is one of this player's commanders standing here?
--
-- Somewhere a commander is already stood is not a place to build a wall: it will
-- buy and carry the same units away in the same turn.
local function standing_here(state, player, id)
	for i = 1, #state.commanders do
		local c = state.commanders[i]
		if c.owner == player and c.at == id then return true end
	end
	return false
end

--- Is anything next to this city held by somebody else?
local function on_the_frontier(realm, state, player, id)
	local neighbours = realm.adjacency[id]
	for i = 1, #neighbours do
		local owner = state.tiles[neighbours[i]].owner
		if owner ~= 0 and owner ~= player then return true end
	end
	return false
end

--- What to load, given what is worth attacking from here.
--
-- **Composition follows the map.** A bot looks at what its own space borders -
-- walls or armies - and buys against whichever it is short of, rather than
-- filling the hold with whatever is cheapest. Line first regardless, because
-- something has to be in front.
local function compose(realm, state, mods, player, commander, berths, purse)
	local walls, ships = 0, 0
	for id = 1, #realm.tiles do
		if state.tiles[id].owner == player then
			local neighbours = realm.adjacency[id]
			for k = 1, #neighbours do
				local n = neighbours[k]
				local owner = state.tiles[n].owner
				if owner ~= 0 and owner ~= player then
					local fortification, army = cost_of(realm, state, mods, n)
					walls = walls + fortification
					ships = ships + army
				end
			end
		end
	end

	local take = units.empty()
	local spent = 0
	-- Half the berths to escorts, the rest to whichever answer the border
	-- actually needs. A bot with no border at all is expanding into empty space
	-- and wants bulk.
	local line = math.floor(berths / 2)
	if line < 1 then line = 1 end
	local second = (ships > walls) and "interceptor" or "bombard"
	for _, plan in ipairs({ { "escort", line }, { second, berths - line } }) do
		local spec = units.by_id(plan[1])
		local n = plan[2]
		local afford = math.floor((purse - spent) / spec.cost)
		if n > afford then n = afford end
		if n > 0 then
			take[plan[1]] = take[plan[1]] + n
			spent = spent + n * spec.cost
		end
	end
	return take
end

--- What to spend a surplus on, if anything.
--
-- One decision a turn, and only ever with a reserve kept back: a bot that spent
-- its purse the moment it could would leave its commander with nothing to embark
-- and lose the ground it had just paid to reach.
--
-- The priorities are the ones a player would reach for. Another commander first,
-- because a second front is worth more than any single city; then an
-- Admiralty if there is nowhere to raise one; then a Bastion where the fighting
-- is, and Yards where it is not.
local function spend(realm, state, player)
	local purse = state.players[player].gold or 0
	local reserve = RESERVE_UNITS * units.by_id("escort").cost

	-- Cities in id order: `pairs` is unspecified and two runtimes have to
	-- agree on what this bot did.
	local cities = {}
	for id = 1, #realm.tiles do
		local sys = state.tiles[id]
		if sys.owner == player and tiles.is_city(realm, id) then
			cities[#cities + 1] = id
		end
	end
	if #cities == 0 then return nil end

	local cap = buildings.commander_cap(state, player)
	local have = #state_mod.commanders_of(state, player)

	if have < cap and purse >= rules.commander_cost + reserve then
		for i = 1, #cities do
			if buildings.has(state.tiles[cities[i]], "admiralty") then
				return { player = player, kind = "recruit", at = cities[i] }
			end
		end
	end

	local function afford(id)
		local spec = buildings.by_id(id)
		return purse >= spec.cost + reserve
	end
	local function propose(id, at)
		return { player = player, kind = "build", at = at, building = id }
	end

	-- **Somewhere to raise officers, before anything else at all.**
	--
	-- Slots are the scarce thing, not gold, and an Admiralty is the dearest
	-- of the four - so a bot that simply bought whatever it could currently
	-- afford filled every city with Yards and Works while saving up, and then
	-- had nowhere left to put one. Eight-city empires finished games having
	-- never raised a second commander.
	--
	-- So: nothing else is built until there is somewhere to raise officers, or
	-- until there is no point having one.
	local wants_admiralty = cap < rules.commander_cap_max
	if wants_admiralty then
		local somewhere = nil
		for i = 1, #cities do
			local sys = state.tiles[cities[i]]
			if buildings.has(sys, "admiralty") then
				somewhere = true
				break
			end
			if not somewhere and buildings.room(sys) then somewhere = cities[i] end
		end
		if somewhere ~= true then
			if not somewhere then return nil end
			if not afford("admiralty") then return nil end
			return propose("admiralty", somewhere)
		end
	end

	-- **Then dwellings, because without one a city makes nothing at all.**
	-- Berths first wherever a city has none - it is the cheapest thing on the
	-- board and the difference between a world that arms you and a world that
	-- does not - then the two that answer whichever half of a fight this
	-- frontier is short of.
	for i = 1, #cities do
		local id = cities[i]
		local sys = state.tiles[id]
		if buildings.room(sys) and not buildings.has(sys, "berths")
			and afford("berths") then
			return propose("berths", id)
		end
	end

	for i = 1, #cities do
		local id = cities[i]
		local sys = state.tiles[id]
		if buildings.room(sys) then
			if on_the_frontier(realm, state, player, id) then
				if not buildings.has(sys, "bastion") and afford("bastion") then
					return propose("bastion", id)
				end
			end
			-- Both dwellings eventually, cheapest first. A bot has no front to
			-- read at the moment it builds - the city it is developing may be
			-- nowhere near the fight by the time anything comes out of it.
			if not buildings.has(sys, "interceptor_bay")
				and afford("interceptor_bay") then
				return propose("interceptor_bay", id)
			end
			if not buildings.has(sys, "foundry") and afford("foundry") then
				return propose("foundry", id)
			end
		end
	end
	return nil
end

--- Orders for one bot player, for the turn about to resolve.
--
-- Returns a list in the same shape a human's submitted batch takes, so the
-- resolver cannot tell the difference - which is the point: a bot that went
-- through a different code path would be playing a different game.
function M.orders(realm, state, player)
	local orders = {}
	local stream = rng.stream(state.seed,
		"bot:" .. player .. ":turn:" .. state.turn)

	local mods = {}
	for i = 1, #state.players do mods[i] = modifiers.of(state.players[i]) end

	-- One purchase a turn, so a windfall is spent over several rather than all
	-- at once - and so the reserve above is checked against a purse that has
	-- not already been emptied twice in the same batch.
	local purchase = spend(realm, state, player)
	if purchase then orders[#orders + 1] = purchase end

	-- `roster` rather than `commanders`: that would shadow the module required
	-- at the top of this file, and `commanders.power` below would resolve
	-- against the array instead.
	local roster = state_mod.commanders_of(state, player)
	for i = 1, #roster do
		local commander = roster[i]
		-- A commander already under way is left alone. Re-routing every turn
		-- would make a bot dither on the spot, and its standing order is
		-- usually still the best one.
		if state_mod.is_parked(commander) then
			local my_mods = mods[player]
			local siege = commanders.power(commander, my_mods, units.FORTIFICATION)
			local army_power = commanders.power(commander, my_mods, units.ARMY)
			local room = commanders.room(commander, my_mods)
			local carried = commanders.carried(commander)
			local purse = state.players[player].gold or 0
			local here = state.tiles[commander.at]
			local cheapest = units.by_id("escort").cost

			-- **Refit, then go - never both in one turn.** Buying and swapping
			-- both happen where the commander *ends* the turn, so issuing either
			-- alongside a march means the city is behind it by the time
			-- logistics runs and the order does nothing. That was the whole
			-- economy idling: bots asked to resupply eight times in a hundred
			-- turns and bought exactly nothing.
			--
			-- Neither costs an order, so a bot spends nothing to stand still
			-- and load - which is the same bargain a player gets.
			local busy = false
			if here.owner == player and room > 0 then
				-- Buy what this city has ready and the purse can reach,
				-- into its garrison.
				local buying = units.empty()
				local ready = units.count(here.available)
				if ready > 0 and purse >= cheapest then
					buying = compose(realm, state, mods, player, commander,
						math.min(room, ready), purse)
					if units.count(buying) > 0 then
						orders[#orders + 1] = {
							player = player, kind = "buy",
							at = commander.at, units = buying,
						}
						busy = true
					end
				end

				-- And take everything standing here that will fit, **including
				-- what is being bought this same turn**: buying settles before
				-- transferring, so the garrison the swap sees is the one this
				-- purchase has already landed in. Reading only what is standing
				-- there now would leave every bot buying units it then walked
				-- away from.
				--
				-- The target is a whole hold, not a delta, so this is simply
				-- "what I have plus as much of that as I can carry".
				local want = units.normalise(commander.units)
				local space, moving = room, 0
				for k = 1, #units.CATALOGUE do
					local id = units.CATALOGUE[k].id
					local n = (here.garrison[id] or 0) + (buying[id] or 0)
					if n > space then n = space end
					if n > 0 then
						want[id] = want[id] + n
						space = space - n
						moving = moving + n
					end
				end
				if moving > 0 then
					orders[#orders + 1] = {
						player = player, kind = "transfer",
						commander = commander.id, units = want,
					}
					busy = true
				end
			end

			-- Too spent to take anything worth taking, and somewhere to refit:
			-- go there. Expansion can wait - a commander at half its berths is one
			-- that will be turned back at the first thing worth attacking.
			if not busy and carried * 2 <= commanders.max_units(commander, my_mods)
				and purse >= cheapest then
				local depot, road = nearest_depot(realm, state, player, commander.at)
				if depot and road and #road > 0 then
					orders[#orders + 1] = {
						player = player, kind = "move",
						commander = commander.id, route = road,
					}
					busy = true
				end
			end

			local targets = busy and {} or reachable_targets(realm, state,
				mods, player, commander.at, siege, army_power, 12)
			local best, best_score = nil, nil
			for t = 1, #targets do
				-- A little noise so two bots in the same position do not make
				-- identical moves forever, drawn from the seeded stream so it
				-- stays reproducible.
				local s = score(realm, targets[t], stream:float() * 0.9)
				if not best_score or s > best_score then
					best, best_score = targets[t], s
				end
			end
			if best and #best.route > 0 then
				orders[#orders + 1] = {
					player = player, kind = "move",
					commander = commander.id, route = best.route,
				}
			end
			-- No affordable target means standing still, which is the right
			-- move: strength only comes back on ground you hold, so a bot with
			-- nothing it can take is a bot refitting for the one it can.
		end
	end

	-- **Garrison the frontier.** Buying costs no order and needs nobody
	-- standing there, so what a city has made is worth turning into a wall
	-- wherever the wall is the thing that matters - which is exactly the
	-- decision the garrison exists to create: push with these, or hold with
	-- them.
	--
	-- Only where a border actually is, and only out of what is left after the
	-- next building is paid for. A bot that garrisoned everywhere would spend
	-- its whole economy standing still, and a bot that spent its last gold on
	-- a wall never develops the city behind it.
	local purse = state.players[player].gold or 0
	local reserve = rules.commander_cost
	if purse > reserve then
		-- Id order: `pairs` is unspecified and two runtimes have to agree on
		-- what this bot did.
		for id = 1, #realm.tiles do
			local sys = state.tiles[id]
			if sys.owner == player and tiles.is_city(realm, id)
				and units.count(sys.available) > 0
				and on_the_frontier(realm, state, player, id)
				and not standing_here(state, player, id) then
				local take, spent = units.empty(), 0
				for k = 1, #units.CATALOGUE do
					local spec = units.CATALOGUE[k]
					local n = sys.available[spec.id] or 0
					local afford = math.floor((purse - reserve - spent) / spec.cost)
					if n > afford then n = afford end
					if n > 0 then
						take[spec.id] = n
						spent = spent + n * spec.cost
					end
				end
				if units.count(take) > 0 then
					orders[#orders + 1] = {
						player = player, kind = "buy", at = id, units = take,
					}
					purse = purse - spent
				end
			end
		end
	end

	return orders
end

--- What one order costs against the turn's allowance.
local function order_cost(order)
	return rules.order_cost[order.kind] or 1
end

--- Trim a bot's turn to the same allowance a human gets.
--
-- **Bots have to be held to the budget too**, or the AI a player faces is one
-- that gets five decisions a turn to their three - which is not a difficulty
-- setting, it is a different game. The order they were generated in is the
-- order they matter in: a purchase first, then commanders by id.
local function within_budget(orders)
	local out, spent = {}, 0
	for i = 1, #orders do
		local cost = order_cost(orders[i])
		-- **Skipped, not stopped.** This used to `break` at the first order it
		-- could not afford, which was right while every kind cost one. Buying
		-- and transferring cost nothing now, so breaking silently threw away
		-- every free order that happened to sit behind a costly one - a bot
		-- would march, and in the same breath drop the purchase it had already
		-- decided on.
		if spent + cost <= rules.orders_per_turn then
			spent = spent + cost
			out[#out + 1] = orders[i]
		end
	end
	return out
end

--- Every bot's orders for this turn, in player order.
---
--- Player order, not table order: `pairs` is unspecified and two runtimes have
--- to agree on what the turn contained.
function M.all_orders(realm, state)
	local out = {}
	for i = 1, #state.players do
		local player = state.players[i]
		if player.bot and player.alive then
			local orders = within_budget(M.orders(realm, state, i))
			for k = 1, #orders do out[#out + 1] = orders[k] end
		end
	end
	return out
end

--- Is this player a bot?
function M.is_bot(state, player)
	local p = state.players[player]
	return (p and p.bot) and true or false
end

-- Naming ----------------------------------------------------------------------

-- Bots are named rather than numbered so a turn report reads like a war and not
-- like a unit test.
local NAMES = {
	"Sable Directorate", "The Quiet Army", "Orsanne Compact",
	"Ninth Ascendancy", "Hollow Court", "Verge Syndicate",
	"Karnath Remnant", "Pale Assembly", "Tessellate",
}

--- A stable name for the nth bot in a game.
function M.name(index)
	return NAMES[((index - 1) % #NAMES) + 1]
end

return M
