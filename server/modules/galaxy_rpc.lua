--- Nakama server entry points for the galaxy prototype.
--
-- The generator is not reimplemented here. ./galaxy is mounted into Nakama's
-- module path by docker-compose.yml, so the server runs byte-for-byte the same
-- Lua the Defold client does. Nakama's runtime is gopher-lua, which has no
-- `bit` library; galaxy/rng.lua detects that and takes an arithmetic path that
-- yields identical results (checked by tools/verify_cross_runtime.sh).

local nk = require("nakama")

local generate = require("galaxy.generate")
local wire = require("galaxy.wire")
local digest = require("galaxy.digest")
local rng = require("galaxy.rng")

-- Seeds are held below 2^24 so they survive a round trip through a Defold
-- go.property, which is a 32-bit float.
local MAX_SEED = 16777215
local DEFAULT_SEED = require("galaxy.config").default_seed

-- Generating a galaxy costs ~100 ms of pure Lua, and every client asking for
-- the same seed must get the same answer anyway, so results are memoised.
-- Nakama pools runtime VMs, so this is a per-VM cache rather than a global one;
-- that is fine, it just warms once per pool member.
local CACHE_LIMIT = 16
local cache = {}
local cache_order = {}

local function cached_galaxy(seed)
	local hit = cache[seed]
	if hit then return hit end

	local started = os.time()
	local g = generate.build(seed)
	local payload = wire.encode(g)
	payload.digest = digest.of(g)
	local encoded = nk.json_encode(payload)

	cache[seed] = encoded
	cache_order[#cache_order + 1] = seed
	if #cache_order > CACHE_LIMIT then
		local evict = table.remove(cache_order, 1)
		cache[evict] = nil
	end

	nk.logger_info(string.format(
		"generated galaxy seed=%d stars=%d lanes=%d regions=%d digest=%d bytes=%d elapsed=%ds bitops=%s",
		seed, g.stats.star_count, g.stats.lane_count, g.stats.region_count,
		payload.digest, #encoded, os.time() - started, rng.implementation))

	return encoded
end

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
	return cached_galaxy(seed_from_payload(payload))
end

nk.register_rpc(rpc_galaxy_get, "galaxy.get")

nk.logger_info("galaxy module loaded (bit-ops: " .. rng.implementation .. ")")
