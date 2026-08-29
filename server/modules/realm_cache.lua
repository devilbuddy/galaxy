--- Shared, memoised access to generated realms.
--
-- Generating one costs several seconds on Nakama's interpreter, and both the
-- map RPC and every turn of every game need the same object, so it is built
-- once per seed. Nakama pools runtime VMs, so this is a per-VM cache: each pool
-- member warms independently, which is fine because the result is identical.

local nk = require("nakama")
local generate = require("realm.generate")
local wire = require("realm.wire")
local digest = require("realm.digest")
local path = require("realm.sim.path")

local M = {}

local LIMIT = 8
local cache = {}
local order = {}

--- The built map for a seed, and its encoded form.
function M.get(seed)
	local hit = cache[seed]
	if hit then return hit end

	local started = os.time()
	local realm = generate.build(seed)
	local payload = wire.encode(realm)
	payload.digest = digest.of(realm)

	local entry = {
		realm = realm,
		encoded = nk.json_encode(payload),
		digest = payload.digest,
	}

	cache[seed] = entry
	order[#order + 1] = seed
	if #order > LIMIT then
		local evict = table.remove(order, 1)
		cache[evict] = nil
	end

	nk.logger_info(string.format(
		"built map seed=%d land=%d sea=%d digest=%d in %ds",
		seed, realm.stats.tile_count, realm.stats.water_count,
		entry.digest, os.time() - started))

	return entry
end

return M
