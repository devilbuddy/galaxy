--- Nakama backend: device authentication and galaxy retrieval.
--
-- Wraps the nakama-defold client so the rest of the game does not have to know
-- about coroutines or REST shapes. Every call is callback-based; internally
-- they run inside `nakama.sync`, which the extension requires because its HTTP
-- calls yield.
--
-- The server is authoritative for the map. It also *generates* it with the same
-- Lua modules this client has (see docker-compose.yml), so a galaxy that
-- arrives over the network is identical to one generated locally from the same
-- seed - which is what makes the local fallback below safe rather than a
-- divergence waiting to happen.

local nakama = require("nakama.nakama")
local nakama_engine = require("nakama.engine.defold")
local nakama_log = require("nakama.util.log")
-- The extension swaps in Defold's native json.encode when it exists and falls
-- back to a pure-Lua one otherwise, so this is safe on every target.
local njson = require("nakama.util.json")
local wire = require("galaxy.wire")

local M = {}

-- idle -> connecting -> ready, or failed
M.state = "idle"
M.error = nil
M.user_id = nil

local client = nil

local function setting(key, default)
	local value = sys.get_config_string("galaxy." .. key, default)
	if value == nil or value == "" then return default end
	return value
end

--- Is the backend switched on at all? With it off the game generates locally,
--- which keeps the prototype usable with no server running.
function M.enabled()
	return setting("use_server", "1") == "1"
end

function M.address()
	return string.format("%s:%s", setting("nakama_host", "127.0.0.1"),
		setting("nakama_port", "7350"))
end

local function ensure_client()
	if client then return client end
	-- The extension logs nothing by default, which makes a failed handshake look
	-- like a hang. galaxy.nakama_debug = 1 turns on full request/response
	-- tracing - useful, but it prints the session token, so keep it off except
	-- while debugging.
	if setting("nakama_debug", "0") == "1" then
		nakama_log.print()
	end
	client = nakama.create_client({
		host = setting("nakama_host", "127.0.0.1"),
		port = tonumber(setting("nakama_port", "7350")),
		use_ssl = setting("nakama_ssl", "0") == "1",
		-- Nakama's "server key" is sent as the HTTP basic-auth username.
		username = setting("nakama_key", "defaultkey"),
		password = "",
		engine = nakama_engine,
		timeout = tonumber(setting("nakama_timeout", "10")),
	})
	return client
end

--- Authenticate with a device id, creating the account on first contact.
-- @param done function(ok, err)
function M.connect(done)
	if M.state == "ready" then
		done(true)
		return
	end
	M.state = "connecting"
	M.error = nil

	local device_id = require("main.device_id").get()
	local c = ensure_client()

	nakama.sync(function()
		local session = nakama.authenticate_device(c, device_id, nil, true, nil)
		if not session or session.error or not session.token then
			M.state = "failed"
			M.error = session and (session.message or tostring(session.error))
				or "no response"
			done(false, M.error)
			return
		end

		nakama.set_bearer_token(c, session.token)
		M.state = "ready"
		M.user_id = session.user_id
		done(true)
	end)
end

function M.ready()
	return M.state == "ready"
end

--- Call a server RPC with a table payload.
--
-- rpc_func (not rpc_func2) because the latter passes the payload as a query
-- parameter, which Nakama delivers to the RPC as an empty string.
-- @param done function(result_table, err)
function M.rpc(name, payload, done)
	if not M.ready() then
		done(nil, "not connected")
		return
	end

	nakama.sync(function()
		local body = njson.encode(payload or {})
		local result = nakama.rpc_func(client, name, body, nil)

		if not result or result.error then
			-- Nakama returns RPC errors as a JSON body; surface the message the
			-- server actually wrote rather than a bare status code.
			local message = result and (result.message or tostring(result.error)) or "no response"
			done(nil, message)
			return
		end

		local ok, decoded = pcall(json.decode, result.payload)
		if not ok or type(decoded) ~= "table" then
			done(nil, "malformed response from " .. name)
			return
		end
		done(decoded)
	end)
end

--- Game lifecycle. Thin wrappers so screens never build payloads by hand.
function M.game_list(done)
	M.rpc("game.list", {}, done)
end

--- Create a game. `options.bots` fills that many seats with bots, which is
--- what makes a game playable without finding three other people.
function M.game_create(options, done)
	M.rpc("game.create", options or {}, done)
end

--- Join an open lobby. `options` carries the display name and race pick; both
--- are optional and the server substitutes defaults for whatever is missing.
function M.game_join(game_id, options, done)
	options = options or {}
	M.rpc("game.join", {
		game_id = game_id,
		player_name = options.player_name,
		race = options.race,
	}, done)
end

function M.game_start(game_id, done)
	M.rpc("game.start", { game_id = game_id }, done)
end

function M.game_state(game_id, since_turn, done)
	M.rpc("game.state", { game_id = game_id, since_turn = since_turn or 0 }, done)
end

function M.game_orders(game_id, orders, done)
	M.rpc("game.orders", { game_id = game_id, orders = orders or {} }, done)
end

--- Ask what path an order would actually take.
--
-- The route is expanded server-side by the same function the resolver uses, so
-- what the map draws is what the turn will fly. `fixed` is the lane a moving
-- fleet has to finish before it can turn, or nil.
-- @param done function(result, err) with result.route as a list of system ids
function M.game_route(game_id, from, waypoints, fixed, done)
	M.rpc("game.route", {
		game_id = game_id, from = from,
		waypoints = waypoints or {}, fixed = fixed,
	}, done)
end

--- Ask the server for the galaxy with this seed.
-- @param done function(galaxy, err, info)
function M.fetch_galaxy(seed, done)
	if not M.ready() then
		done(nil, "not connected")
		return
	end

	nakama.sync(function()
		-- The request body is trivial, so it is built by hand rather than
		-- pulling in an encoder.
		--
		-- rpc_func, not rpc_func2: the latter sends the payload as a `?payload=`
		-- query parameter, which Nakama 3.27 hands to the RPC as an empty
		-- string. The server then silently fell back to its default seed, so
		-- every request returned the same galaxy. rpc_func POSTs the payload as
		-- the request body, which arrives intact.
		local request = string.format('{"seed":%d}', math.floor(seed))
		local result = nakama.rpc_func(client, "galaxy.get", request, nil)

		if not result or result.error then
			done(nil, result and (result.message or tostring(result.error)) or "no response")
			return
		end

		local ok, decoded = pcall(json.decode, result.payload)
		if not ok or type(decoded) ~= "table" then
			done(nil, "malformed galaxy payload")
			return
		end

		local built
		ok, built = pcall(wire.decode, decoded)
		if not ok then
			done(nil, tostring(built))
			return
		end

		done(built, nil, { digest = decoded.digest, bytes = #result.payload })
	end)
end

return M
