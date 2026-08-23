--- Nakama server entry points for the galaxy prototype.
--
-- The generator is not reimplemented here. ./galaxy is mounted into Nakama's
-- module path by docker-compose.yml, so the server runs byte-for-byte the same
-- Lua the Defold client does. Nakama's runtime is gopher-lua, which has no
-- `bit` library; galaxy/rng.lua detects that and takes an arithmetic path that
-- yields identical results (checked by tools/verify_cross_runtime.sh).

local nk = require("nakama")

local galaxy_cache = require("galaxy_cache")
local rng = require("galaxy.rng")

-- Seeds are held below 2^24 so they survive a round trip through a Defold
-- go.property, which is a 32-bit float.
local MAX_SEED = 16777215
local DEFAULT_SEED = require("galaxy.config").default_seed

--- Normalise whatever the client sent into a usable seed.
--
-- Both fallbacks below are logged. An earlier client bug sent the payload as a
-- query parameter, which Nakama delivers as an empty string; the server quietly
-- defaulted and served the same galaxy for every seed, which took far too long
-- to notice. Silently substituting a default is exactly the kind of thing that
-- should be visible in the log.
local function seed_from_payload(payload)
	if not payload or payload == "" then
		nk.logger_warn(string.format(
			"galaxy.get: empty payload, falling back to default seed %d", DEFAULT_SEED))
		return DEFAULT_SEED
	end

	local ok, decoded = pcall(nk.json_decode, payload)
	if not ok or type(decoded) ~= "table" then
		error({ ["message"] = "payload must be a JSON object, got: " .. tostring(payload) }, 0)
	end

	local seed = tonumber(decoded.seed)
	if not seed then
		nk.logger_warn(string.format(
			"galaxy.get: payload had no numeric seed (%s), using default %d",
			tostring(payload), DEFAULT_SEED))
		return DEFAULT_SEED
	end

	seed = math.floor(seed)
	if seed < 0 then seed = -seed end
	if seed == 0 then return DEFAULT_SEED end
	-- Wrap rather than reject: any integer names *some* galaxy.
	return seed % MAX_SEED
end

--- RPC "galaxy.get" -> the full generated map for a seed.
local function rpc_galaxy_get(context, payload)
	return galaxy_cache.get(seed_from_payload(payload)).encoded
end

nk.register_rpc(rpc_galaxy_get, "galaxy.get")

nk.logger_info("galaxy module loaded (bit-ops: " .. rng.implementation .. ")")
