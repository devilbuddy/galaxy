--- Game lifecycle: lobbies, orders, and scheduled turn resolution.
--
-- Turns are resolved lazily. There is no scheduler: every RPC first asks
-- whether any turns are due and resolves however many were missed. For a game
-- where players check in twice a day that is exactly right, it needs neither a
-- cron nor Nakama's Go runtime, and it cannot drift. The one consequence is
-- that if nobody touches a game, it does not advance until somebody does.
--
-- Storage layout (Nakama storage engine; the Lua runtime has no SQL access):
--
--   games         / <id>              system-owned  lobby + schedule + roster
--   game_state    / <id>              system-owned  the mutable simulation
--   game_events   / <id>:<turn>       system-owned  one turn's events
--   game_orders   / <id>:<turn>       per-user      that player's orders
--
-- Everything is system-owned except orders, so a player cannot read another
-- player's pending moves by asking storage directly.

local nk = require("nakama")

local galaxy_cache = require("galaxy_cache")
local sim_state = require("galaxy.sim.state")
local resolve = require("galaxy.sim.resolve")
local view = require("galaxy.sim.view")
local rng = require("galaxy.rng")

local M = {}

local GAMES = "games"
local STATE = "game_state"
local EVENTS = "game_events"
local ORDERS = "game_orders"

local MAX_SEED = 16777215
local DEFAULT_INTERVAL = 12 * 60 * 60  -- twice a day
local MIN_INTERVAL = 30                -- so a game can be exercised quickly in dev
local MAX_PLAYERS = 10
local MIN_PLAYERS = 2
-- A game left alone for a month should not try to resolve sixty turns inside
-- one request; it catches up over several instead.
local MAX_CATCHUP_PER_CALL = 12

-- Storage helpers -----------------------------------------------------------

local function read_one(collection, key, user_id)
	local ok, objects = pcall(nk.storage_read, {
		{ collection = collection, key = key, user_id = user_id },
	})
	if not ok or not objects or #objects == 0 then return nil, nil end
	return objects[1].value, objects[1].version
end

--- Write, optionally guarded by the version we read.
--
-- Two players hitting a game at the same instant would otherwise both resolve
-- the same turn. Passing the version we based our work on makes the second
-- write fail, and the caller re-reads instead of double-resolving.
local function write_one(collection, key, user_id, value, version)
	local record = {
		collection = collection,
		key = key,
		value = value,
		permission_read = user_id and 1 or 2,
		permission_write = 0, -- server only; clients never write these directly
	}
	if user_id then record.user_id = user_id end
	if version then record.version = version end
	return pcall(nk.storage_write, { record })
end

--- Repair a state that has been round-tripped through JSON storage.
--
-- Sim state is stored as JSON. Dense arrays (systems, fleets, players) survive
-- intact, but `knowledge[player]` is keyed by star id and is *sparse*, so it
-- encodes as an object and comes back with string keys. Indexing it with a
-- number would then silently miss, and every player's fog-of-war memory would
-- appear empty after the first turn - the map would forget everything it had
-- seen, every turn, with no error anywhere.
local function normalise_state(state)
	if not state then return nil end
	if type(state.knowledge) ~= "table" then
		state.knowledge = {}
		return state
	end
	local repaired = {}
	for player, memory in pairs(state.knowledge) do
		local by_id = {}
		if type(memory) == "table" then
			for id, seen in pairs(memory) do
				by_id[tonumber(id) or id] = seen
			end
		end
		repaired[tonumber(player) or player] = by_id
	end
	state.knowledge = repaired
	state.fleets = state.fleets or {}
	return state
end

local function fail(message)
	error({ message = message }, 0)
end

local function decode_payload(payload)
	if not payload or payload == "" then return {} end
	local ok, decoded = pcall(nk.json_decode, payload)
	if not ok or type(decoded) ~= "table" then fail("payload must be a JSON object") end
	return decoded
end

-- Game records ---------------------------------------------------------------

local function player_index(game, user_id)
	for i = 1, #game.players do
		if game.players[i].id == user_id then return i end
	end
	return nil
end

local function public_game(game)
	return {
		id = game.id,
		name = game.name,
		status = game.status,
		seed = game.seed,
		turn = game.turn,
		max_players = game.max_players,
		turn_interval = game.turn_interval,
		next_turn_at = game.next_turn_at,
		star_count = game.star_count,
		players = (function()
			local out = {}
			for i = 1, #game.players do
				out[i] = { name = game.players[i].name }
			end
			return out
		end)(),
	}
end

-- Turn resolution -------------------------------------------------------------

--- Resolve every turn that is due. Returns how many were resolved.
local function catch_up(game, game_version)
	if game.status ~= "active" then return 0, game_version end

	local now = os.time()
	if now < game.next_turn_at then return 0, game_version end

	local entry = galaxy_cache.get(game.seed)
	local state, state_version = read_one(STATE, game.id, nil)
	state = normalise_state(state)
	if not state then return 0, game_version end

	local resolved = 0
	while now >= game.next_turn_at and resolved < MAX_CATCHUP_PER_CALL do
		local turn = state.turn + 1

		-- Gather each player's orders for the turn about to resolve.
		local orders = {}
		for i = 1, #game.players do
			local submitted = read_one(ORDERS, game.id .. ":" .. turn, game.players[i].id)
			if submitted and submitted.orders then
				for k = 1, #submitted.orders do
					local o = submitted.orders[k]
					orders[#orders + 1] = {
						player = i,
						from = tonumber(o.from),
						to = tonumber(o.to),
						ships = tonumber(o.ships),
					}
				end
			end
		end

		local events = resolve.turn(entry.galaxy, state, orders, entry.lengths)
		write_one(EVENTS, game.id .. ":" .. turn, nil, { turn = turn, events = events })

		game.turn = state.turn
		game.next_turn_at = game.next_turn_at + game.turn_interval
		resolved = resolved + 1

		local remaining = 0
		for i = 1, #state.players do
			if state.players[i].alive then remaining = remaining + 1 end
		end
		if remaining <= 1 then
			game.status = "finished"
			break
		end
	end

	if resolved > 0 then
		-- The state write is version-guarded; if it loses the race another
		-- caller already resolved these turns and this work is simply dropped.
		local ok = write_one(STATE, game.id, nil, state, state_version)
		if not ok then
			nk.logger_warn("game " .. game.id .. ": lost turn-resolution race, discarding")
			return 0, game_version
		end
		local ok2, acks = write_one(GAMES, game.id, nil, game, game_version)
		if ok2 and acks and acks[1] then game_version = acks[1].version end
		nk.logger_info(string.format("game %s resolved %d turn(s) to turn %d",
			game.id, resolved, game.turn))
	end

	return resolved, game_version
end

-- RPCs --------------------------------------------------------------------------

--- game.create { name, seed?, star_count?, max_players?, turn_interval? }
local function rpc_create(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")

	local seed = tonumber(input.seed)
	if not seed or seed <= 0 then
		-- os.time alone would collide for two games created in the same second.
		seed = rng.hash(user_id .. ":" .. tostring(os.time()) .. ":" .. tostring(os.clock()))
	end
	seed = math.floor(seed) % MAX_SEED

	local max_players = math.floor(tonumber(input.max_players) or 4)
	if max_players < MIN_PLAYERS then max_players = MIN_PLAYERS end
	if max_players > MAX_PLAYERS then max_players = MAX_PLAYERS end

	local interval = math.floor(tonumber(input.turn_interval) or DEFAULT_INTERVAL)
	if interval < MIN_INTERVAL then interval = MIN_INTERVAL end

	local game = {
		id = nk.uuid_v4(),
		name = tostring(input.name or "Untitled"),
		status = "lobby",
		seed = seed,
		star_count = tonumber(input.star_count) or nil,
		turn = 0,
		turn_interval = interval,
		next_turn_at = 0,
		max_players = max_players,
		players = { { id = user_id, name = tostring(input.player_name or "Commander") } },
		created_at = os.time(),
	}

	write_one(GAMES, game.id, nil, game)
	nk.logger_info(string.format("game %s created by %s (seed %d, %d players max)",
		game.id, user_id, seed, max_players))
	return nk.json_encode({ game = public_game(game) })
end

--- game.list {} - open lobbies, and separately the caller's own games.
--
-- A player needs both: something to join, and a way back into games already
-- under way. Without the split the client cannot tell whether a listed game is
-- one to join or one to resume.
local function rpc_list(context, payload)
	local user_id = context.user_id
	local objects = nk.storage_list(nil, GAMES, 200, nil)
	local open, mine = {}, {}

	if objects then
		for i = 1, #objects do
			local game = objects[i].value
			if game and game.id then
				if user_id and player_index(game, user_id) then
					if game.status ~= "finished" then
						mine[#mine + 1] = public_game(game)
					end
				elseif game.status == "lobby" and #game.players < game.max_players then
					open[#open + 1] = public_game(game)
				end
			end
		end
	end

	local by_id = function(a, b) return a.id < b.id end
	table.sort(open, by_id)
	table.sort(mine, by_id)
	return nk.json_encode({ games = open, mine = mine })
end

--- game.join { game_id }
local function rpc_join(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")
	local game, version = read_one(GAMES, tostring(input.game_id or ""), nil)
	if not game then fail("no such game") end
	if game.status ~= "lobby" then fail("that game has already started") end
	if player_index(game, user_id) then
		return nk.json_encode({ game = public_game(game), already = true })
	end
	if #game.players >= game.max_players then fail("that game is full") end

	game.players[#game.players + 1] = {
		id = user_id,
		name = tostring(input.player_name or ("Commander " .. (#game.players + 1))),
	}
	local ok = write_one(GAMES, game.id, nil, game, version)
	if not ok then fail("someone else joined at the same moment, try again") end
	return nk.json_encode({ game = public_game(game) })
end

--- game.start { game_id } - only a player in the lobby may start it.
local function rpc_start(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")
	local game, version = read_one(GAMES, tostring(input.game_id or ""), nil)
	if not game then fail("no such game") end
	if not player_index(game, user_id) then fail("you are not in that game") end
	if game.status ~= "lobby" then fail("that game has already started") end
	if #game.players < MIN_PLAYERS then fail("need at least " .. MIN_PLAYERS .. " players") end

	local entry = galaxy_cache.get(game.seed)
	local state = sim_state.new(entry.galaxy, game.players)

	game.status = "active"
	game.turn = 0
	-- The first turn lands a full interval after the start, so everyone gets
	-- the same amount of time to issue their opening orders.
	game.next_turn_at = os.time() + game.turn_interval

	write_one(STATE, game.id, nil, state)
	local ok = write_one(GAMES, game.id, nil, game, version)
	if not ok then fail("game changed while starting, try again") end

	nk.logger_info(string.format("game %s started with %d players, first turn at %d",
		game.id, #game.players, game.next_turn_at))
	return nk.json_encode({ game = public_game(game) })
end

--- game.state { game_id, since_turn? } - the player's view plus what they missed.
local function rpc_state(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")
	local game, version = read_one(GAMES, tostring(input.game_id or ""), nil)
	if not game then fail("no such game") end

	local me = player_index(game, user_id)
	if not me then fail("you are not in that game") end

	catch_up(game, version)
	-- Re-read: catch_up may have advanced things, and may have lost a race.
	game = read_one(GAMES, game.id, nil) or game

	local response = { game = public_game(game), you = me, now = os.time() }

	if game.status ~= "lobby" then
		local state = normalise_state(read_one(STATE, game.id, nil))
		if state then
			local entry = galaxy_cache.get(game.seed)
			response.view = view.project(entry.galaxy, state, me)

			-- Everything that happened since the client last looked, filtered to
			-- what this player is allowed to know.
			local since = math.floor(tonumber(input.since_turn) or 0)
			local first = math.max(1, since + 1)
			local keys = {}
			for t = first, state.turn do
				keys[#keys + 1] = { collection = EVENTS, key = game.id .. ":" .. t }
			end
			local digest_events = {}
			if #keys > 0 then
				local ok, objects = pcall(nk.storage_read, keys)
				if ok and objects then
					table.sort(objects, function(a, b) return a.key < b.key end)
					for i = 1, #objects do
						local bundle = objects[i].value
						if bundle and bundle.events then
							for e = 1, #bundle.events do
								local event = bundle.events[e]
								local visible = false
								if event.visible_to then
									for v = 1, #event.visible_to do
										if event.visible_to[v] == me then visible = true break end
									end
								else
									visible = true
								end
								if visible then
									-- Do not ship the recipient list to the client.
									event.visible_to = nil
									digest_events[#digest_events + 1] = event
								end
							end
						end
					end
				end
			end
			response.events = digest_events
		end
	end

	return nk.json_encode(response)
end

--- game.orders { game_id, orders: [ { from, to, ships } ] }
--
-- Orders replace whatever was previously submitted for the coming turn, so a
-- player can revise their plan any number of times before it resolves.
local function rpc_orders(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")
	local game, version = read_one(GAMES, tostring(input.game_id or ""), nil)
	if not game then fail("no such game") end
	if game.status ~= "active" then fail("that game is not running") end

	local me = player_index(game, user_id)
	if not me then fail("you are not in that game") end

	catch_up(game, version)
	game = read_one(GAMES, game.id, nil) or game

	local incoming = input.orders
	if type(incoming) ~= "table" then fail("orders must be an array") end

	local clean = {}
	for i = 1, #incoming do
		local o = incoming[i]
		local from, to, ships = tonumber(o.from), tonumber(o.to), tonumber(o.ships)
		if from and to and ships and ships > 0 then
			clean[#clean + 1] = { from = math.floor(from), to = math.floor(to), ships = math.floor(ships) }
		end
	end

	local turn = game.turn + 1
	write_one(ORDERS, game.id .. ":" .. turn, user_id, { turn = turn, orders = clean })

	return nk.json_encode({
		accepted = #clean,
		for_turn = turn,
		resolves_at = game.next_turn_at,
	})
end

nk.register_rpc(rpc_create, "game.create")
nk.register_rpc(rpc_list, "game.list")
nk.register_rpc(rpc_join, "game.join")
nk.register_rpc(rpc_start, "game.start")
nk.register_rpc(rpc_state, "game.state")
nk.register_rpc(rpc_orders, "game.orders")

nk.logger_info("game module loaded")
