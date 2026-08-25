--- What a bot does with its turn.
--
-- Engine-free, like the rest of `galaxy/sim`, so the same code decides a bot's
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
-- has one verb - move a captain along a route - so the entire decision is
-- "which system next", and a tree there is ceremony around an `if`. When a bot
-- has to weigh expanding against defending against raiding against building,
-- that is the moment to reach for one.
--
-- **It knows what a fight costs.** Combat is a single visible comparison, so a
-- bot can price a target exactly the way a player can, and it simply never
-- picks one it cannot afford. What it does not do yet is defend, retreat, or
-- wait deliberately for a promotion - it waits only because it has run out of
-- things it can pay for.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local state_mod = require("galaxy.sim.state")
local systems = require("galaxy.sim.systems")
local commanders = require("galaxy.sim.commanders")
local modifiers = require("galaxy.sim.modifiers")
local buildings = require("galaxy.sim.buildings")

local M = {}

-- How a bot picks among equally-near targets. Colonies are worth more than
-- empty rock even with nothing to produce yet, because they are what regions
-- are counted in.
local KIND_BONUS = { colony = 2.0, outpost = 1.0, waypoint = 0 }

-- Taking something off somebody is worth more than walking into empty space -
-- it is the only thing that moves a border - but it costs strength that would
-- otherwise have bought two or three free systems, so the premium is modest.
local CONTESTED_BONUS = 1.5

--- What it would cost this bot to take `id` from whoever holds it.
--
-- The same sum the resolver does, and deliberately so: a bot working from a
-- different estimate would march into fights it cannot win, which is the exact
-- mistake "never walk into a border" was written to stop.
local function cost_of(galaxy, state, mods, id)
	local sys = state.systems[id]
	local owner = sys.owner
	local total = systems.defence(galaxy, id, sys.capital_of == owner, mods[owner])
	for i = 1, #state.captains do
		local c = state.captains[i]
		if c.owner == owner and c.at == id then
			total = total + commanders.strength(c, mods[owner])
		end
	end
	return total
end

--- Walk back up the search tree to the route that reaches `id`.
--
-- **The route matters, not just the destination.** A bot picks its target by
-- walking only through ground it already holds - but an order carries a
-- destination, and `resolve.expand_route` pathfinds it across the *whole*
-- graph, which will happily route through somebody else's space and be turned
-- back at the border. Naming every step as a waypoint is what makes the order
-- take the path the bot actually reasoned about.
--
-- Truncated to what a captain is allowed to plot, so a depot on the far side of
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
	-- Drop the start, which the captain is already standing on.
	for i = #reversed - 1, 1, -1 do
		route[#route + 1] = reversed[i]
		if #route >= limit then break end
	end
	return route
end

--- The nearest systems worth going to, reachable without crossing a border.
--
-- Breadth-first out from `from`, walking only through space this player already
-- holds - a captain that has to fight its way *to* a target has spent the
-- strength it was going to take the target with.
--
-- Two kinds of target: unclaimed ground, which is free, and a neighbour's
-- system the captain can currently afford. Anything dearer than the strength in
-- hand is not a target at all, because the resolver would simply turn the
-- captain back at the border and the trip would be wasted.
local function reachable_targets(galaxy, state, mods, player, from, strength, limit)
	local dist = { [from] = 0 }
	local parent = {}
	local queue, head = { from }, 1
	local found = {}

	while head <= #queue and #found < limit do
		local id = queue[head]
		head = head + 1
		local neighbours = galaxy.adjacency[id]
		for k = 1, #neighbours do
			local n = neighbours[k]
			if not dist[n] then
				dist[n] = dist[id] + 1
				parent[n] = id
				local owner = state.systems[n].owner
				if owner == 0 then
					found[#found + 1] = { id = n, hops = dist[n], cost = 0 }
				elseif owner == player then
					queue[#queue + 1] = n
				else
					local cost = cost_of(galaxy, state, mods, n)
					if strength >= cost then
						found[#found + 1] = { id = n, hops = dist[n], cost = cost }
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

--- The nearest colony of this player's that has anything worth collecting.
--
-- Same walk as `reachable_targets`, through their own ground only - a captain
-- that has to fight its way to a depot arrives with nothing to put in it.
local function nearest_depot(galaxy, state, player, from)
	local parent = {}
	local seen = { [from] = true }
	local queue, head = { from }, 1
	while head <= #queue do
		local id = queue[head]
		head = head + 1
		local sys = state.systems[id]
		if sys.owner == player and (sys.stock or 0) > 0 and id ~= from then
			return id, route_to(parent, id, rules.max_route_hops)
		end
		local neighbours = galaxy.adjacency[id]
		for k = 1, #neighbours do
			local n = neighbours[k]
			if not seen[n] and state.systems[n].owner == player then
				seen[n] = true
				parent[n] = id
				queue[#queue + 1] = n
			end
		end
	end
	return nil
end

--- Score a candidate. Near beats far, and something worth holding beats rock.
local function score(galaxy, candidate, jitter)
	local kind = systems.kind(galaxy, candidate.id)
	return (KIND_BONUS[kind] or 0)
		+ (candidate.cost > 0 and CONTESTED_BONUS or 0)
		- candidate.hops * 1.5
		+ jitter
end

-- Kept back so a bot never builds itself out of an army. Two units is enough to
-- top a captain up on the next colony it reaches.
local RESERVE_UNITS = 2

--- Is anything next to this colony held by somebody else?
local function on_the_frontier(galaxy, state, player, id)
	local neighbours = galaxy.adjacency[id]
	for i = 1, #neighbours do
		local owner = state.systems[neighbours[i]].owner
		if owner ~= 0 and owner ~= player then return true end
	end
	return false
end

--- What to spend a surplus on, if anything.
--
-- One decision a turn, and only ever with a reserve kept back: a bot that spent
-- its purse the moment it could would leave its captain with nothing to embark
-- and lose the ground it had just paid to reach.
--
-- The priorities are the ones a player would reach for. Another captain first,
-- because a second front is worth more than any single colony; then an
-- Admiralty if there is nowhere to raise one; then a Bastion where the fighting
-- is, and Yards where it is not.
local function spend(galaxy, state, player)
	local purse = state.players[player].supply or 0
	local reserve = RESERVE_UNITS * rules.unit_cost

	-- Colonies in id order: `pairs` is unspecified and two runtimes have to
	-- agree on what this bot did.
	local colonies = {}
	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner == player and systems.is_colony(galaxy, id) then
			colonies[#colonies + 1] = id
		end
	end
	if #colonies == 0 then return nil end

	local cap = buildings.captain_cap(state, player)
	local have = #state_mod.captains_of(state, player)

	if have < cap and purse >= rules.captain_cost + reserve then
		for i = 1, #colonies do
			if buildings.has(state.systems[colonies[i]], "admiralty") then
				return { player = player, kind = "recruit", at = colonies[i] }
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
	-- Slots are the scarce thing, not supply, and an Admiralty is the dearest
	-- of the four - so a bot that simply bought whatever it could currently
	-- afford filled every colony with Yards and Works while saving up, and then
	-- had nowhere left to put one. Eight-colony empires finished games having
	-- never raised a second captain.
	--
	-- So: nothing else is built until there is somewhere to raise officers, or
	-- until there is no point having one.
	local wants_admiralty = cap < rules.captain_cap_max
	if wants_admiralty then
		local somewhere = nil
		for i = 1, #colonies do
			local sys = state.systems[colonies[i]]
			if buildings.has(sys, "admiralty") then
				somewhere = true
				break
			end
			if not somewhere and buildings.room(sys) then somewhere = colonies[i] end
		end
		if somewhere ~= true then
			if not somewhere then return nil end
			if not afford("admiralty") then return nil end
			return propose("admiralty", somewhere)
		end
	end

	for i = 1, #colonies do
		local id = colonies[i]
		local sys = state.systems[id]
		if buildings.room(sys) then
			if on_the_frontier(galaxy, state, player, id) then
				if not buildings.has(sys, "bastion") and afford("bastion") then
					return propose("bastion", id)
				end
			else
				if not buildings.has(sys, "yards") and afford("yards") then
					return propose("yards", id)
				end
				if not buildings.has(sys, "works") and afford("works") then
					return propose("works", id)
				end
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
function M.orders(galaxy, state, player)
	local orders = {}
	local stream = rng.stream(state.seed,
		"bot:" .. player .. ":turn:" .. state.turn)

	local mods = {}
	for i = 1, #state.players do mods[i] = modifiers.of(state.players[i]) end

	-- One purchase a turn, so a windfall is spent over several rather than all
	-- at once - and so the reserve above is checked against a purse that has
	-- not already been emptied twice in the same batch.
	local purchase = spend(galaxy, state, player)
	if purchase then orders[#orders + 1] = purchase end

	local captains = state_mod.captains_of(state, player)
	for i = 1, #captains do
		local captain = captains[i]
		-- A captain already under way is left alone. Re-routing every turn
		-- would make a bot dither on the spot, and its standing order is
		-- usually still the best one.
		if state_mod.is_parked(captain) then
			local strength = commanders.strength(captain, mods[player])
			local full = commanders.max_strength(captain, mods[player])
			local purse = state.players[player].supply or 0
			local here = state.systems[captain.at]

			-- **Refit, then go - never both in one turn.** A captain buys where
			-- it *ends* the turn, so issuing a purchase and a march together
			-- means the colony is behind it by the time logistics runs and the
			-- order is refused. That was the whole economy doing nothing: bots
			-- asked to resupply eight times in a hundred turns and bought
			-- exactly nothing.
			local busy = false
			if here.owner == player and (here.stock or 0) > 0
				and purse >= rules.unit_cost then
				-- **Only if there is a whole unit's worth of room.** A captain
				-- one point short of full asks for `floor(1 / 2)` units, which
				-- is none - and then stands there having spent its turn on an
				-- order that does nothing, for ever. Every long game ended with
				-- both survivors' whole rosters doing exactly this.
				local room = math.floor((full - strength) / rules.unit_strength)
				local take = math.min(room, here.stock,
					math.floor(purse / rules.unit_cost))
				if take > 0 then
					orders[#orders + 1] = {
						player = player, kind = "resupply",
						captain = captain.id, units = take,
					}
					busy = true
				end
			end

			-- Too spent to take anything worth taking, and somewhere to refit:
			-- go there. Expansion can wait - a captain at half strength is one
			-- that will be turned back at the first thing worth attacking.
			if not busy and strength * 2 <= full and purse >= rules.unit_cost then
				local depot, road = nearest_depot(galaxy, state, player, captain.at)
				if depot and road and #road > 0 then
					orders[#orders + 1] = {
						player = player, kind = "move",
						captain = captain.id, route = road,
					}
					busy = true
				end
			end

			local targets = busy and {} or reachable_targets(galaxy, state,
				mods, player, captain.at, strength, 12)
			local best, best_score = nil, nil
			for t = 1, #targets do
				-- A little noise so two bots in the same position do not make
				-- identical moves forever, drawn from the seeded stream so it
				-- stays reproducible.
				local s = score(galaxy, targets[t], stream:float() * 0.9)
				if not best_score or s > best_score then
					best, best_score = targets[t], s
				end
			end
			if best and #best.route > 0 then
				orders[#orders + 1] = {
					player = player, kind = "move",
					captain = captain.id, route = best.route,
				}
			end
			-- No affordable target means standing still, which is the right
			-- move: strength only comes back on ground you hold, so a bot with
			-- nothing it can take is a bot refitting for the one it can.
		end
	end
	return orders
end

--- Every bot's orders for this turn, in player order.
---
--- Player order, not table order: `pairs` is unspecified and two runtimes have
--- to agree on what the turn contained.
function M.all_orders(galaxy, state)
	local out = {}
	for i = 1, #state.players do
		local player = state.players[i]
		if player.bot and player.alive then
			local orders = M.orders(galaxy, state, i)
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
	"Sable Directorate", "The Quiet Fleet", "Orsanne Compact",
	"Ninth Ascendancy", "Hollow Court", "Verge Syndicate",
	"Karnath Remnant", "Pale Assembly", "Tessellate",
}

--- A stable name for the nth bot in a game.
function M.name(index)
	return NAMES[((index - 1) % #NAMES) + 1]
end

return M
