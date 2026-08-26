--- Game state: creation, and the small helpers the rest of the sim needs.
--
-- State holds only what cannot be derived. The galaxy is a pure function of the
-- seed, so it is never stored, and neither is anything computed from it - what
-- kind of place a system is (galaxy/sim/systems.lua) or who holds a region
-- (galaxy/sim/regions.lua) are recomputed on demand.
--
-- The game is being rebuilt from the ground up, and this is the foundation:
--
--   * every player has a **capital**, which is theirs from the first turn and
--     is the one place they will eventually build;
--   * every player has a single **captain**, a named officer who moves along
--     the lane graph, claims what they pass through, and spends **strength** to
--     take ground somebody else holds.
--
-- There is no production and no research yet. Strength comes from rank and is
-- recovered by standing on your own ground, which is the placeholder a city
-- producing unit types will replace.

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local races = require("galaxy.sim.races")
local systems = require("galaxy.sim.systems")
local commanders = require("galaxy.sim.commanders")
local units = require("galaxy.sim.units")

local M = {}

-- Opening position --------------------------------------------------------------

local function pick_capitals(galaxy, count, r)
	local stars = galaxy.stars
	local n = #stars

	-- Candidates, best first: a well-connected colony with neighbours worth
	-- taking. The random tiebreak keeps two games on the same seed from opening
	-- identically only if the player count differs.
	local candidates = {}
	for i = 1, n do
		if systems.is_colony(galaxy, i) and #galaxy.adjacency[i] > 0 then
			local nearby = systems.colonies_within(galaxy, i, rules.capital_hops)
			candidates[#candidates + 1] = {
				id = i,
				nearby = nearby,
				score = nearby * 10 + #galaxy.adjacency[i] + r:float(),
			}
		end
	end
	table.sort(candidates, function(p, q)
		if p.score ~= q.score then return p.score > q.score end
		return p.id < q.id
	end)

	-- Prefer candidates that clear the room-to-expand bar, but never fail to
	-- place a player: a crowded map is better than no game.
	local pool = {}
	for i = 1, #candidates do
		if candidates[i].nearby >= rules.capital_neighbours then
			pool[#pool + 1] = candidates[i].id
		end
	end
	if #pool < count then
		for i = 1, #candidates do
			local id = candidates[i].id
			local already = false
			for k = 1, #pool do
				if pool[k] == id then already = true break end
			end
			if not already then pool[#pool + 1] = id end
			if #pool >= count then break end
		end
	end
	if #pool == 0 then
		-- No colonies at all. Should not happen with the generator's floor, but
		-- a game that cannot start is worse than a game on bad ground.
		for i = 1, n do pool[#pool + 1] = i end
	end

	-- Then spread: the first is the best candidate, each subsequent one is the
	-- pool entry farthest from every home chosen so far. Two players opening as
	-- neighbours would decide the game in the first few turns.
	local capitals = { pool[1] }
	local nearest = {}
	for i = 1, #pool do
		local dx = stars[pool[i]].x - stars[pool[1]].x
		local dy = stars[pool[i]].y - stars[pool[1]].y
		nearest[i] = dx * dx + dy * dy
	end

	while #capitals < count do
		local pick, pickd = nil, -1
		for i = 1, #pool do
			if nearest[i] > pickd then pick, pickd = i, nearest[i] end
		end
		if not pick then break end
		capitals[#capitals + 1] = pool[pick]
		nearest[pick] = -1
		for i = 1, #pool do
			if nearest[i] >= 0 then
				local dx = stars[pool[i]].x - stars[pool[pick]].x
				local dy = stars[pool[i]].y - stars[pool[pick]].y
				local d = dx * dx + dy * dy
				if d < nearest[i] then nearest[i] = d end
			end
		end
	end
	return capitals
end

-- Opening state ------------------------------------------------------------------

--- Build the opening state for a game.
-- @param galaxy  a generated galaxy (see galaxy/generate.lua)
-- @param players array of { id = <string>, name = <string>, race = <string> }
function M.new(galaxy, players)
	local r = rng.stream(galaxy.seed, "capitals")
	local capitals = pick_capitals(galaxy, #players, r)

	local state = {
		seed = galaxy.seed,
		turn = 0,
		players = {},
		systems = {},
		captains = {},
		next_captain_id = 1,
		-- Per-player memory of what they have seen. Fog of war without this
		-- would make the map flicker between known and unknown as captains move.
		knowledge = {},
		-- Recomputed every turn; stored only so a change can be reported.
		regions_held = {},
		winner = nil,
	}

	for i = 1, #galaxy.stars do
		-- `stock` is units a colony holds ready. Only colonies ever accumulate
		-- it, but every system carries the field so a JSON round trip does not
		-- have to distinguish "no stock" from "cannot have stock".
		state.systems[i] = { owner = 0, capital_of = 0, stock = 0, buildings = {} }
	end

	for i = 1, #players do
		local capital = capitals[i]
		state.players[i] = {
			id = players[i].id,
			name = players[i].name,
			race = races.exists(players[i].race) and players[i].race or races.DEFAULT,
			-- Carried into the simulation so `bots.all_orders` can find them.
			-- Nothing else in the resolver reads it: a bot's orders arrive in
			-- the same shape a human's do and are treated identically.
			bot = players[i].bot and true or nil,
			capital = capital,
			alive = true,
			next_commander_number = 1,
			-- The empire purse. Fungible across the whole map, which is what
			-- makes it different from stock: supply can be earned in one arm
			-- and spent in another, units cannot.
			supply = 0,
		}
		state.systems[capital].owner = i
		state.systems[capital].capital_of = i
		state.knowledge[i] = {}
		M.add_captain(state, i, capital)
	end

	return state
end

-- Captains -------------------------------------------------------------------------

--- Raise a captain, standing at `at`.
function M.add_captain(state, owner, at)
	local player = state.players[owner]
	local number = player.next_commander_number
	local captain = {
		id = state.next_captain_id,
		owner = owner,
		name = commanders.name(player),
		number = number,
		-- Everything else about an officer - rank, how fast they move, how much
		-- they can spend, the face they wear - derives from these, so state
		-- carries nothing it can compute.
		level = 1,
		xp = 0,
		-- An empty hold. A newly raised officer has their own command and
		-- nothing aboard; everything else is bought at a colony, which is what
		-- turns an economy into a map problem.
		units = units.empty(),
		at = at,
		route = {},
	}
	state.next_captain_id = state.next_captain_id + 1
	state.captains[#state.captains + 1] = captain
	return captain
end

function M.captain_by_id(state, id)
	for i = 1, #state.captains do
		if state.captains[i].id == id then return state.captains[i] end
	end
	return nil
end

--- Every captain a player has in the field, lowest id first.
function M.captains_of(state, owner)
	local out = {}
	for i = 1, #state.captains do
		if state.captains[i].owner == owner then out[#out + 1] = state.captains[i] end
	end
	table.sort(out, function(p, q) return p.id < q.id end)
	return out
end

--- Is this captain standing still?
function M.is_parked(captain)
	return #captain.route == 0
end

--- The system a moving captain is heading for next, or nil.
function M.next_hop(captain)
	return captain.route[1]
end

--- Where a broken captain reforms.
--
-- The capital, and only the capital. A defeated officer is not killed - with
-- one captain each, losing it outright would leave a player with no move to
-- make for the rest of the game - but being thrown the whole way home is a real
-- cost in a game where a lane is a turn, and it is the one place strength comes
-- back quickly.
--
-- Falls back to where they already stand for a player whose capital has been
-- taken; they are about to be eliminated anyway, and a nil here would be a
-- crash in the middle of turn resolution.
function M.refuge(state, captain)
	local player = state.players[captain.owner]
	local capital = player and player.capital
	if capital and state.systems[capital]
		and state.systems[capital].owner == captain.owner then
		return capital
	end
	return captain.at
end

-- Aggregates ---------------------------------------------------------------------

--- Systems a player currently holds, lowest id first.
function M.owned_by(state, player)
	local out = {}
	for id, sys in pairs(state.systems) do
		if sys.owner == player then out[#out + 1] = id end
	end
	table.sort(out) -- pairs() order is undefined; sort for reproducibility
	return out
end

function M.holdings_of(state, player)
	local n = 0
	for _, sys in pairs(state.systems) do
		if sys.owner == player then n = n + 1 end
	end
	return n
end

--- Does this player still hold their capital?
---
--- The only losing condition there is, for now. A player who cannot be pushed
--- off their capital cannot be eliminated, which is correct while nobody has an
--- army to push with.
function M.holds_capital(state, player)
	local capital = state.players[player] and state.players[player].capital
	return capital ~= nil and state.systems[capital].owner == player
end

function M.is_alive(state, player)
	return M.holds_capital(state, player)
end

-- Repair -------------------------------------------------------------------------

--- Put a state back together after a JSON round trip.
--
-- Nakama stores state as JSON. Dense arrays survive, but `knowledge[player]` is
-- keyed by star id and *sparse*, so it comes back with string keys - and
-- indexing it with a number would then silently miss, leaving every player's
-- memory of the map looking empty after every turn.
function M.normalise(state)
	if type(state) ~= "table" then return state end
	state.systems = state.systems or {}
	state.captains = state.captains or {}
	state.players = state.players or {}

	local systems_out = {}
	for id, sys in pairs(state.systems) do
		local key = tonumber(id)
		if key then
			sys.owner = tonumber(sys.owner) or 0
			sys.capital_of = tonumber(sys.capital_of) or 0
			sys.stock = tonumber(sys.stock) or 0
			-- A dense array of strings, so it survives JSON intact - but an
			-- empty one encodes as an object on some encoders and comes back as
			-- a table with no length, which `#` then reads as zero anyway. The
			-- rebuild keeps only what is actually a known id.
			local built = {}
			if type(sys.buildings) == "table" then
				for b = 1, #sys.buildings do
					local id = sys.buildings[b]
					if type(id) == "string" then built[#built + 1] = id end
				end
			end
			sys.buildings = built
			systems_out[key] = sys
		end
	end
	state.systems = systems_out

	local knowledge = {}
	for player, seen in pairs(state.knowledge or {}) do
		local pk = tonumber(player)
		if pk then
			local out = {}
			for id, entry in pairs(seen) do
				local key = tonumber(id)
				if key then
					-- An entry is what was seen there, not just when. This used
					-- to coerce it with `tonumber(entry) or 0`, which was right
					-- when memory was id -> turn and silently flattened every
					-- record to the number zero once `view.remember` started
					-- storing a table. The symptom was the whole point of this
					-- function inverted: fog memory was wiped on every read, so
					-- the map forgot everything the moment it left live view -
					-- and `view.project` crashed outright the first time a
					-- player remembered somewhere they could no longer see.
					if type(entry) == "table" then
						out[key] = {
							turn = tonumber(entry.turn) or 0,
							owner = tonumber(entry.owner) or 0,
							capital_of = tonumber(entry.capital_of) or 0,
						}
					else
						-- A record written before memory carried what was seen.
						out[key] = {
							turn = tonumber(entry) or 0,
							owner = 0, capital_of = 0,
						}
					end
				end
			end
			knowledge[pk] = out
		end
	end
	state.knowledge = knowledge

	for i = 1, #state.captains do
		local c = state.captains[i]
		c.route = c.route or {}
		-- Movement used to be a distance along a lane, and captains stored how
		-- far down one they were. Nothing reads it now; dropping it keeps
		-- stored state from describing a rule the game no longer has.
		c.progress = nil
		c.level = tonumber(c.level) or 1
		c.xp = tonumber(c.xp) or 0
		-- Deliberately allowed to stay nil: `commanders.strength` reads that as
		-- a full complement, which is what every captain in a game that
		-- predates strength should come back as.
		-- The hold, dense and integer again. A record from before types carried
		-- a single `strength` number instead; there is no honest way to split
		-- that into three, so it becomes an empty hold and the officer keeps
		-- their own command.
		c.units = units.normalise(c.units)
		c.strength = nil
		-- Transient: set when an order is read and consumed the same turn in
		-- the logistics phase. A value that survived a round trip would have a
		-- captain buying again on a turn nobody asked it to.
		c.buying = nil
	end

	for i = 1, #state.players do
		local player = state.players[i]
		-- Nil rather than zero for a game that predates the purse would read as
		-- "no supply for ever": nothing else ever writes it.
		player.supply = tonumber(player.supply) or 0
	end

	state.turn = tonumber(state.turn) or 0
	state.regions_held = state.regions_held or {}
	return state
end

return M
