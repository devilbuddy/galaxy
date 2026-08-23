--- Shared, memoised access to generated galaxies.
--
-- Generating one costs several seconds on Nakama's interpreter, and both the
-- map RPC and every turn of every game need the same object, so it is built
-- once per seed. Nakama pools runtime VMs, so this is a per-VM cache: each pool
-- member warms independently, which is fine because the result is identical.

local nk = require("nakama")
local generate = require("galaxy.generate")
local wire = require("galaxy.wire")
local digest = require("galaxy.digest")
local path = require("galaxy.sim.path")

local M = {}

local LIMIT = 8
local cache = {}
local order = {}

--- The built galaxy for a seed, plus its lane-length lookup and encoded form.
function M.get(seed)
	local hit = cache[seed]
	if hit then return hit end

	local started = os.time()
	local galaxy = generate.build(seed)
	local payload = wire.encode(galaxy)
	payload.digest = digest.of(galaxy)

	local entry = {
		galaxy = galaxy,
		lengths = path.lane_lengths(galaxy),
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
		"built galaxy seed=%d stars=%d lanes=%d digest=%d in %ds",
		seed, galaxy.stats.star_count, galaxy.stats.lane_count,
		entry.digest, os.time() - started))

	return entry
end

return M
