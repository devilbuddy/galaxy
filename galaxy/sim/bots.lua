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

local rng = require("galaxy.rng")
local state_mod = require("galaxy.sim.state")
local systems = require("galaxy.sim.systems")

local M = {}

-- How a bot picks among equally-near targets. Colonies are worth more than
-- empty rock even with nothing to produce yet, because they are what regions
-- are counted in.
local KIND_BONUS = { colony = 2.0, outpost = 1.0, waypoint = 0 }

--- The nearest unclaimed systems reachable without crossing someone's border.
--
-- Breadth-first out from `from`, walking only through space this player already
-- holds. A captain turned back at a border has wasted the turn it took to get
-- there, so a route that ends at one is never worth plotting.
local function reachable_targets(galaxy, state, player, from, limit)
	local dist = { [from] = 0 }
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
				local owner = state.systems[n].owner
				if owner == 0 then
					found[#found + 1] = { id = n, hops = dist[n] }
				elseif owner == player then
					queue[#queue + 1] = n
				end
				-- Somebody else's ground is neither a target nor a road.
			end
		end
	end
	return found
end

--- Score a candidate. Near beats far, and something worth holding beats rock.
local function score(galaxy, candidate, jitter)
	local kind = systems.kind(galaxy, candidate.id)
	return (KIND_BONUS[kind] or 0)
		- candidate.hops * 1.5
		+ jitter
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

	local captains = state_mod.captains_of(state, player)
	for i = 1, #captains do
		local captain = captains[i]
		-- A captain already under way is left alone. Re-routing every turn
		-- would make a bot dither on the spot, and its standing order is
		-- usually still the best one.
		if state_mod.is_parked(captain) then
			local targets = reachable_targets(galaxy, state, player, captain.at, 12)
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
			if best then
				orders[#orders + 1] = {
					player = player, kind = "move",
					captain = captain.id, route = { best.id },
				}
			end
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
