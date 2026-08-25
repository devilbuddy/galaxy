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
local modifiers = require("galaxy.sim.modifiers")
local view = require("galaxy.sim.view")
local races = require("galaxy.sim.races")
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
-- ...and however many turns were missed, only the most recent few are worth
-- reading. A player coming back to a game that ran for weeks does not want two
-- hundred turns of digest, the payload would be large, and the client cannot
-- render it: an unbounded event list exhausted the GUI node budget outright.
local MAX_DIGEST_TURNS = 40

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
-- Sim state is stored as JSON. Dense arrays (systems, captains, players)
-- survive intact, but `knowledge[player]` is keyed by star id and is *sparse*,
-- so it encodes as an object and comes back with string keys. Indexing it with
-- a number would then silently miss, and every player's fog-of-war memory would
-- appear empty after the first turn - the map would forget everything it had
-- seen, every turn, with no error anywhere.
--
-- The repair itself lives in the sim (`state.normalise`), so the rules and the
-- repair for them cannot drift apart.
local function normalise_state(state)
	if not state then return nil end
	return sim_state.normalise(state)
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
		winner = game.winner,
		seed = game.seed,
		turn = game.turn,
		max_players = game.max_players,
		turn_interval = game.turn_interval,
		next_turn_at = game.next_turn_at,
		star_count = game.star_count,
		players = (function()
			local out = {}
			for i = 1, #game.players do
				-- Race is public from the lobby onwards: knowing what you are
				-- about to be up against is part of choosing your own.
				out[i] = { name = game.players[i].name, race = game.players[i].race }
			end
			return out
		end)(),
	}
end

-- Turn resolution -------------------------------------------------------------

--- Has every player still in the game submitted orders for the coming turn?
--
-- Submitting is what ends a player's turn, so once the last one is in there is
-- nothing left to wait for. Waiting out the clock anyway is the single worst
-- thing an asynchronous game can do to four people who are all paying
-- attention at the same time.
--
-- An order record existing is the whole test. A player with nothing to do still
-- submits - an empty batch is how "I am done" is said.
local function everyone_submitted(game, turn)
	local waiting = 0
	for i = 1, #game.players do
		local player = game.players[i]
		if player.alive ~= false then
			local submitted = read_one(ORDERS, game.id .. ":" .. turn, player.id)
			if not submitted then waiting = waiting + 1 end
		end
	end
	return waiting == 0
end

--- Resolve every turn that is due. Returns how many were resolved.
local function catch_up(game, game_version)
	if game.status ~= "active" then return 0, game_version end

	local now = os.time()
	local early = everyone_submitted(game, game.turn + 1)
	if now < game.next_turn_at and not early then return 0, game_version end

	local entry = galaxy_cache.get(game.seed)
	local state, state_version = read_one(STATE, game.id, nil)
	state = normalise_state(state)
	if not state then return 0, game_version end

	local resolved = 0
	-- `early` only ever unlocks the *first* turn of this call: once it has
	-- resolved, nobody has submitted for the one after it, so the loop falls
	-- back to the clock and cannot run away.
	while (early or now >= game.next_turn_at) and resolved < MAX_CATCHUP_PER_CALL do
		local turn = state.turn + 1

		-- Gather each player's orders for the turn about to resolve.
		local orders = {}
		for i = 1, #game.players do
			local submitted = read_one(ORDERS, game.id .. ":" .. turn, game.players[i].id)
			if submitted and submitted.orders then
				for k = 1, #submitted.orders do
					local o = submitted.orders[k]
					local route = nil
					if type(o.route) == "table" then
						route = {}
						for w = 1, #o.route do
							local id = tonumber(o.route[w])
							if id then route[#route + 1] = math.floor(id) end
						end
					end
					orders[#orders + 1] = {
						player = i,
						kind = o.kind,
						captain = tonumber(o.captain),
						route = route,
					}
				end
			end
		end

		local events = resolve.turn(entry.galaxy, state, orders, entry.lengths)
		write_one(EVENTS, game.id .. ":" .. turn, nil, { turn = turn, events = events })

		game.turn = state.turn
		if early then
			-- Everyone was ready, so the clock restarts from now rather than
			-- from a deadline that has not arrived. Otherwise four prompt
			-- players would find the next turn already half over.
			game.next_turn_at = now + game.turn_interval
			early = false
		else
			game.next_turn_at = game.next_turn_at + game.turn_interval
		end
		resolved = resolved + 1

		-- Holding enough regions wins outright (galaxy/sim/regions.lua). The
		-- resolver decides it; this only has to notice and stop the clock.
		if state.winner then
			game.status = "finished"
			game.winner = state.winner
			break
		end

		local remaining = 0
		for i = 1, #state.players do
			if state.players[i].alive then remaining = remaining + 1 end
		end
		if remaining <= 1 then
			game.status = "finished"
			for i = 1, #state.players do
				if state.players[i].alive then game.winner = i end
			end
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
		players = { {
			id = user_id,
			name = tostring(input.player_name or "Commander"),
			race = races.exists(input.race) and input.race or races.DEFAULT,
		} },
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
		race = races.exists(input.race) and input.race or races.DEFAULT,
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
			if state.turn - first + 1 > MAX_DIGEST_TURNS then
				first = state.turn - MAX_DIGEST_TURNS + 1
			end
			-- Told to the client so it can say what it is not showing, rather
			-- than silently presenting a partial history as the whole thing.
			response.events_from = first
			local keys = {}
			for t = first, state.turn do
				keys[#keys + 1] = { collection = EVENTS, key = game.id .. ":" .. t }
			end
			local digest_events = {}
			if #keys > 0 then
				local ok, objects = pcall(nk.storage_read, keys)
				if ok and objects then
					-- By turn *number*, not by key. The keys are
					-- "<game>:<turn>", so a string sort orders turn 10 before
					-- turn 2 and the digest a player reads is shuffled from
					-- turn ten onwards - which looks like the simulation
					-- misbehaving rather than like a sort.
					local turn_of = {}
					for i = 1, #objects do
						turn_of[objects[i].key] =
							tonumber(string.match(objects[i].key, ":(%d+)$")) or 0
					end
					table.sort(objects, function(a, b)
						if turn_of[a.key] ~= turn_of[b.key] then
							return turn_of[a.key] < turn_of[b.key]
						end
						return a.key < b.key
					end)
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

--- game.route { game_id, from, waypoints } - what path would this order take?
--
-- The client draws a route the moment an order is issued, and it must be the
-- route the turn will actually fly. Rather than reimplement the pathfinder
-- client-side - where it would run on a fogged view and quietly disagree - the
-- expansion is asked for here and runs the identical function the resolver
-- uses (`resolve.expand_route`).
--
-- Read-only: it inspects nothing but the public map and the caller's own
-- modifiers, and changes no state.
local function rpc_route(context, payload)
	local input = decode_payload(payload)
	local user_id = context.user_id or fail("must be authenticated")
	local game = read_one(GAMES, tostring(input.game_id or ""), nil)
	if not game then fail("no such game") end

	local me = player_index(game, user_id)
	if not me then fail("you are not in that game") end

	local from = tonumber(input.from)
	if not from then fail("no starting system") end

	local waypoints = {}
	if type(input.waypoints) == "table" then
		for i = 1, #input.waypoints do
			local id = tonumber(input.waypoints[i])
			if id then waypoints[#waypoints + 1] = math.floor(id) end
		end
	end
	if #waypoints == 0 then fail("nowhere to go") end

	local entry = galaxy_cache.get(game.seed)
	local state = read_one(STATE, game.id, nil)
	local player = state and state.players and state.players[me]
	local mods = modifiers.of(player)

	local route, why = resolve.expand_route(entry.galaxy, entry.lengths,
		math.floor(from), tonumber(input.fixed), waypoints, mods.hops)
	if not route then
		return nk.json_encode({ route = {}, reason = why or "no route" })
	end
	return nk.json_encode({ route = route })
end

--- game.orders { game_id, orders: [ order ] }
--
-- There is one order:
--   { kind = "move", captain, route }   send a captain along a list of waypoints
--
-- An empty batch is meaningful: it is how a player says "I am done this turn",
-- which is what lets the turn resolve early once everyone has said it.
--
-- Orders replace whatever was previously submitted for the coming turn, so a
-- player can revise their plan any number of times before it resolves. The
-- checks here are shape-only: whether an order is *legal* depends on state that
-- will have moved on by the time it resolves, so the resolver decides that and
-- emits an `order_rejected` event carrying a reason the client can show.
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

	--- A route as a list of system ids, or nil when the shape is wrong - which
	--- the caller reads as "no route given" rather than as an error.
	local function clean_route(value)
		if type(value) ~= "table" then return nil end
		local out = {}
		for i = 1, #value do
			local id = tonumber(value[i])
			if id then out[#out + 1] = math.floor(id) end
		end
		return out
	end

	local clean = {}

	--- Drop earlier orders this one supersedes. A captain takes one order a
	--- turn, so the array's position never carries meaning a client would have
	--- to know about.
	local function replace(match)
		for k = #clean, 1, -1 do
			if match(clean[k]) then table.remove(clean, k) end
		end
	end

	for i = 1, #incoming do
		local o = incoming[i]
		if o.kind == "move" then
			local captain = tonumber(o.captain)
			if captain then
				local entry = {
					kind = "move", captain = math.floor(captain),
					route = clean_route(o.route) or {},
				}
				replace(function(c) return c.captain == entry.captain end)
				clean[#clean + 1] = entry
			end
		end
	end

	local turn = game.turn + 1
	write_one(ORDERS, game.id .. ":" .. turn, user_id, { turn = turn, orders = clean })

	-- Submitting ends this player's turn, so the game may now be ready to run
	-- without waiting for the clock. Checked here rather than on the next poll
	-- because the player who submits last should see the result immediately.
	local resolved = catch_up(game, nil)

	return nk.json_encode({
		accepted = #clean,
		for_turn = turn,
		resolved = resolved,
		resolves_at = game.next_turn_at,
	})
end

nk.register_rpc(rpc_create, "game.create")
nk.register_rpc(rpc_list, "game.list")
nk.register_rpc(rpc_join, "game.join")
nk.register_rpc(rpc_start, "game.start")
nk.register_rpc(rpc_state, "game.state")
nk.register_rpc(rpc_orders, "game.orders")
nk.register_rpc(rpc_route, "game.route")

nk.logger_info("game module loaded")
