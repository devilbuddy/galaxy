--- Game state: creation, and the small helpers the rest of the sim needs.
--
-- State holds only what cannot be derived. The realm is a pure function of the
-- seed, so it is never stored, and neither is anything computed from it - what
-- kind of place a tile is (realm/sim/tiles.lua) or who holds a province
-- (realm/sim/provinces.lua) are recomputed on demand.
--
-- The game is being rebuilt from the ground up, and this is the foundation:
--
--   * every player has a **seat**, which is theirs from the first turn and
--     is the one place they will eventually build;
--   * every player has a single **commander**, a named officer who moves along
--     the tile graph, claims what they pass through, and spends **strength** to
--     take ground somebody else holds.
--
-- There is no production and no research yet. Strength comes from rank and is
-- recovered by standing on your own ground, which is the placeholder a city
-- producing unit types will replace.

local rng = require("realm.rng")
local rules = require("realm.sim.rules")
local races = require("realm.sim.races")
local tiles = require("realm.sim.tiles")
local commanders = require("realm.sim.commanders")
local units = require("realm.sim.units")

local M = {}

-- Opening position --------------------------------------------------------------

local function pick_seats(realm, count, r)
	-- `list`, not `tiles`: a local by that name would shadow the module required
	-- at the top of this file, and `tiles.is_city` below would then resolve
	-- against the array. That is exactly what the vocabulary rename did, and it
	-- is invisible until a game tries to start.
	local list = realm.tiles
	local n = #list

	-- Candidates, best first: a well-connected city with neighbours worth
	-- taking. The random tiebreak keeps two games on the same seed from opening
	-- identically only if the player count differs.
	local candidates = {}
	for i = 1, n do
		if tiles.is_city(realm, i) and #realm.adjacency[i] > 0 then
			local nearby = tiles.cities_within(realm, i, rules.seat_hops)
			candidates[#candidates + 1] = {
				id = i,
				nearby = nearby,
				score = nearby * 10 + #realm.adjacency[i] + r:float(),
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
		if candidates[i].nearby >= rules.seat_neighbours then
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
		-- No cities at all. Should not happen with the generator's floor, but
		-- a game that cannot start is worse than a game on bad ground.
		for i = 1, n do pool[#pool + 1] = i end
	end

	-- Then spread: the first is the best candidate, each subsequent one is the
	-- pool entry farthest from every home chosen so far. Two players opening as
	-- neighbours would decide the game in the first few turns.
	local seats = { pool[1] }
	local nearest = {}
	for i = 1, #pool do
		local dx = list[pool[i]].x - list[pool[1]].x
		local dy = list[pool[i]].y - list[pool[1]].y
		nearest[i] = dx * dx + dy * dy
	end

	while #seats < count do
		local pick, pickd = nil, -1
		for i = 1, #pool do
			if nearest[i] > pickd then pick, pickd = i, nearest[i] end
		end
		if not pick then break end
		seats[#seats + 1] = pool[pick]
		nearest[pick] = -1
		for i = 1, #pool do
			if nearest[i] >= 0 then
				local dx = list[pool[i]].x - list[pool[pick]].x
				local dy = list[pool[i]].y - list[pool[pick]].y
				local d = dx * dx + dy * dy
				if d < nearest[i] then nearest[i] = d end
			end
		end
	end
	return seats
end

-- Opening state ------------------------------------------------------------------

--- Build the opening state for a game.
-- @param realm  a generated realm (see realm/generate.lua)
-- @param players array of { id = <string>, name = <string>, race = <string> }
function M.new(realm, players)
	-- Frozen label; see the note in realm/generate.lua.
	local r = rng.stream(realm.seed, "capitals")
	local seats = pick_seats(realm, #players, r)

	local state = {
		seed = realm.seed,
		turn = 0,
		players = {},
		tiles = {},
		commanders = {},
		next_commander_id = 1,
		-- Per-player memory of what they have seen. Fog of war without this
		-- would make the map flicker between known and unknown as commanders move.
		knowledge = {},
		-- Recomputed every turn; stored only so a change can be reported.
		provinces_held = {},
		winner = nil,
	}

	for i = 1, #realm.tiles do
		-- Two complements per tile, and they are not the same thing:
		--
		--   `available`  what the dwellings have produced and nobody has paid
		--                for. Accumulates per type, up to that dwelling's cap.
		--   `garrison`   what has been bought. Sits here until a commander
		--                carries it away, and defends the world meanwhile.
		--
		-- Every tile carries both, dense, even though only cities with
		-- dwellings ever fill them: a JSON round trip should not have to
		-- distinguish "empty" from "cannot have any", and a table of named
		-- zeroes survives where a sparse one comes back with no keys at all.
		state.tiles[i] = {
			owner = 0, seat_of = 0, buildings = {},
			available = units.empty(), garrison = units.empty(),
		}
	end

	for i = 1, #players do
		local seat = seats[i]
		state.players[i] = {
			id = players[i].id,
			name = players[i].name,
			race = races.exists(players[i].race) and players[i].race or races.DEFAULT,
			-- Carried into the simulation so `bots.all_orders` can find them.
			-- Nothing else in the resolver reads it: a bot's orders arrive in
			-- the same shape a human's do and are treated identically.
			bot = players[i].bot and true or nil,
			seat = seat,
			alive = true,
			next_commander_number = 1,
			-- The empire purse. Fungible across the whole map, which is what
			-- makes it different from a garrison: gold can be earned in one
			-- arm and spent in another, units cannot.
			gold = 0,
		}
		state.tiles[seat].owner = i
		state.tiles[seat].seat_of = i
		-- **A seat opens with Berths standing.** A city makes only what it
		-- has dwellings for, and a player who cannot arm at all until they have
		-- saved the price of one has no opening - they watch a number climb for
		-- several turns and do nothing. Handing everyone the cheapest dwelling
		-- is what the game this is lifted from does on day one, and for the
		-- same reason.
		state.tiles[seat].buildings = { "berths" }
		state.knowledge[i] = {}
		M.add_commander(state, i, seat)
	end

	return state
end

-- Commanders -------------------------------------------------------------------------

--- Raise a commander, standing at `at`.
function M.add_commander(state, owner, at)
	local player = state.players[owner]
	local number = player.next_commander_number
	local commander = {
		id = state.next_commander_id,
		owner = owner,
		name = commanders.name(player),
		number = number,
		-- Everything else about an officer - rank, how fast they move, how much
		-- they can spend, the face they wear - derives from these, so state
		-- carries nothing it can compute.
		level = 1,
		xp = 0,
		-- An empty hold. A newly raised officer has their own command and
		-- nothing aboard; everything else is bought at a city, which is what
		-- turns an economy into a map problem.
		units = units.empty(),
		at = at,
		route = {},
	}
	state.next_commander_id = state.next_commander_id + 1
	state.commanders[#state.commanders + 1] = commander
	return commander
end

function M.commander_by_id(state, id)
	for i = 1, #state.commanders do
		if state.commanders[i].id == id then return state.commanders[i] end
	end
	return nil
end

--- Every commander a player has in the field, lowest id first.
function M.commanders_of(state, owner)
	local out = {}
	for i = 1, #state.commanders do
		if state.commanders[i].owner == owner then out[#out + 1] = state.commanders[i] end
	end
	table.sort(out, function(p, q) return p.id < q.id end)
	return out
end

--- Is this commander standing still?
function M.is_parked(commander)
	return #commander.route == 0
end

--- The tile a moving commander is heading for next, or nil.
function M.next_hop(commander)
	return commander.route[1]
end

--- Where a broken commander reforms.
--
-- The seat, and only the seat. A defeated officer is not killed - with
-- one commander each, losing it outright would leave a player with no move to
-- make for the rest of the game - but being thrown the whole way home is a real
-- cost in a game where a tile is a turn, and it is the one place strength comes
-- back quickly.
--
-- Falls back to where they already stand for a player whose seat has been
-- taken; they are about to be eliminated anyway, and a nil here would be a
-- crash in the middle of turn resolution.
function M.refuge(state, commander)
	local player = state.players[commander.owner]
	local seat = player and player.seat
	if seat and state.tiles[seat]
		and state.tiles[seat].owner == commander.owner then
		return seat
	end
	return commander.at
end

-- Aggregates ---------------------------------------------------------------------

--- Tiles a player currently holds, lowest id first.
function M.owned_by(state, player)
	local out = {}
	for id, sys in pairs(state.tiles) do
		if sys.owner == player then out[#out + 1] = id end
	end
	table.sort(out) -- pairs() order is undefined; sort for reproducibility
	return out
end

function M.holdings_of(state, player)
	local n = 0
	for _, sys in pairs(state.tiles) do
		if sys.owner == player then n = n + 1 end
	end
	return n
end

--- Does this player still hold their seat?
---
--- The only losing condition there is, for now. A player who cannot be pushed
--- off their seat cannot be eliminated, which is correct while nobody has an
--- army to push with.
function M.holds_seat(state, player)
	local seat = state.players[player] and state.players[player].seat
	return seat ~= nil and state.tiles[seat].owner == player
end

function M.is_alive(state, player)
	return M.holds_seat(state, player)
end

-- Repair -------------------------------------------------------------------------

--- Put a state back together after a JSON round trip.
--
-- Nakama stores state as JSON. Dense arrays survive, but `knowledge[player]` is
-- keyed by tile id and *sparse*, so it comes back with string keys - and
-- indexing it with a number would then silently miss, leaving every player's
-- memory of the map looking empty after every turn.
function M.normalise(state)
	if type(state) ~= "table" then return state end
	state.tiles = state.tiles or {}
	state.commanders = state.commanders or {}
	state.players = state.players or {}

	local tiles_out = {}
	for id, sys in pairs(state.tiles) do
		local key = tonumber(id)
		if key then
			sys.owner = tonumber(sys.owner) or 0
			sys.seat_of = tonumber(sys.seat_of) or 0
			-- Both round-trip as objects of named integers; `units.normalise`
			-- is the one place that shape is repaired, and it also carries
			-- renamed type ids across.
			sys.available = units.normalise(sys.available)
			sys.garrison = units.normalise(sys.garrison)
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
			tiles_out[key] = sys
		end
	end
	state.tiles = tiles_out

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
							seat_of = tonumber(entry.seat_of) or 0,
						}
					else
						-- A record written before memory carried what was seen.
						out[key] = {
							turn = tonumber(entry) or 0,
							owner = 0, seat_of = 0,
						}
					end
				end
			end
			knowledge[pk] = out
		end
	end
	state.knowledge = knowledge

	for i = 1, #state.commanders do
		local c = state.commanders[i]
		c.route = c.route or {}
		-- Movement used to be a distance along a tile, and commanders stored how
		-- far down one they were. Nothing reads it now; dropping it keeps
		-- stored state from describing a rule the game no longer has.
		c.progress = nil
		c.level = tonumber(c.level) or 1
		c.xp = tonumber(c.xp) or 0
		-- Deliberately allowed to stay nil: `commanders.strength` reads that as
		-- a full complement, which is what every commander in a game that
		-- predates strength should come back as.
		-- The hold, dense and integer again. A record from before types carried
		-- a single `strength` number instead; there is no honest way to split
		-- that into three, so it becomes an empty hold and the officer keeps
		-- their own command.
		c.units = units.normalise(c.units)
		c.strength = nil
		-- Transient: set when an order is read and consumed the same turn in
		-- the logistics phase. A value that survived a round trip would have a
		-- commander buying again on a turn nobody asked it to.
		c.buying = nil
	end

	for i = 1, #state.players do
		local player = state.players[i]
		-- Nil rather than zero for a game that predates the purse would read as
		-- "no gold for ever": nothing else ever writes it.
		player.gold = tonumber(player.gold) or 0
	end

	state.turn = tonumber(state.turn) or 0
	state.provinces_held = state.provinces_held or {}
	return state
end

return M
