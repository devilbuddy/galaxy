--- A stable per-install device identifier for Nakama device authentication.
--
-- Deliberately not derived from anything about the hardware. Defold's
-- `sys.get_sys_info().device_ident` is empty or restricted on modern iOS and
-- Android for privacy reasons, and using a real hardware id would make the
-- account impossible to reset. A random id generated once and persisted to the
-- save directory is what Nakama's device auth expects, and it survives app
-- restarts while disappearing if the player clears app data.

local M = {}

local APP_NAME = "realm"
local FILENAME = "device_id"

--- 32 hex characters. Nakama requires 10-128.
local function generate()
	-- Identity, not gameplay: this is the one place a non-deterministic seed is
	-- wanted, so the clock is exactly the right source.
	math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 1000000))
	-- The first draw after seeding is poor on some Lua implementations.
	math.random(); math.random()
	-- Drawn in 16-bit chunks. Formatting a full 31-bit draw with %08x produced
	-- sign-extended 64-bit output ("ffffffff85270000"), because the value does
	-- not fit the 32-bit field the format implies. Small chunks avoid it.
	local parts = {}
	for i = 1, 8 do
		parts[i] = string.format("%04x", math.random(0, 65535))
	end
	return table.concat(parts)
end

--- The persisted id, creating one on first run.
function M.get()
	local path = sys.get_save_file(APP_NAME, FILENAME)
	local stored = sys.load(path)
	if stored and type(stored.id) == "string" and #stored.id >= 10 then
		return stored.id
	end

	local id = generate()
	if not sys.save(path, { id = id }) then
		-- Saving can fail on a read-only filesystem; a session-scoped id still
		-- lets the player in, they just get a fresh account next launch.
		print("realm: could not persist device id, using a session-scoped one")
	end
	return id
end

return M
