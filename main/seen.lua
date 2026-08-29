--- How far each game's digest has been read, across app restarts.
--
-- The client has always told the server the last turn it saw - `game.state`
-- takes a `since_turn` and the server only sends events after it. What it did
-- not do was *remember* that number: `store.seen_turn` was a plain module
-- value, so every launch asked for everything since turn 0 and got back the
-- whole window the server is willing to send (MAX_DIGEST_TURNS, forty turns).
-- Opening a game you had been reading five minutes earlier replayed a fortnight.
--
-- Persisted per game rather than globally, because a player with three games on
-- the go has read each of them to a different point.

local M = {}

local APP_NAME = "realm"
local FILENAME = "seen_turns"
-- Enough for far more games than anyone has open; the cap only exists so an
-- abandoned save file cannot grow without bound.
local MAX_ENTRIES = 40

local data = nil
local dirty_seq = 0

local function path()
	return sys.get_save_file(APP_NAME, FILENAME)
end

local function load()
	if data then return data end
	local stored = sys.load(path())
	if type(stored) == "table" and type(stored.games) == "table" then
		data = stored
		dirty_seq = tonumber(stored.seq) or 0
	else
		data = { games = {}, seq = 0 }
	end
	return data
end

--- Drop the least recently touched entries once there are too many.
local function prune(d)
	local ids = {}
	for id in pairs(d.games) do ids[#ids + 1] = id end
	if #ids <= MAX_ENTRIES then return end
	-- Sorted by last touch, oldest first. `pairs` order is unspecified, so the
	-- sort is what makes which entries survive predictable.
	table.sort(ids, function(a, b)
		local ta, tb = d.games[a].seq or 0, d.games[b].seq or 0
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	for i = 1, #ids - MAX_ENTRIES do d.games[ids[i]] = nil end
end

--- The last turn whose digest this device has shown for `game_id`.
function M.get(game_id)
	if not game_id then return 0 end
	local d = load()
	local entry = d.games[tostring(game_id)]
	return (entry and tonumber(entry.turn)) or 0
end

--- Remember that everything up to `turn` has been read.
--
-- Never moves backwards: a stale response arriving after a newer one must not
-- reopen a digest the player has already dismissed.
function M.set(game_id, turn)
	if not game_id or type(turn) ~= "number" then return end
	local d = load()
	local key = tostring(game_id)
	local entry = d.games[key]
	if entry and (tonumber(entry.turn) or 0) >= turn then return end

	dirty_seq = dirty_seq + 1
	d.seq = dirty_seq
	d.games[key] = { turn = turn, seq = dirty_seq }
	prune(d)
	if not sys.save(path(), d) then
		-- A read-only filesystem costs the player a repeated digest, nothing
		-- more, so this is worth a line in the log and not an error.
		print("realm: could not persist how far the digest has been read")
	end
end

--- Forget everything that has been read.
--
-- A digest marks itself read when it is opened, which is right for playing and
-- wrong for looking: the playback worth watching cannot be watched twice. This
-- puts every game back to turn zero so the next open replays the whole window
-- the server is willing to send.
--
-- Debug-only in practice (see main/dev.lua), but it lives here because this is
-- the module that owns the file.
function M.forget()
	data = { games = {}, seq = 0 }
	dirty_seq = 0
	if not sys.save(path(), data) then
		print("realm: could not clear how far the digest has been read")
		return false
	end
	return true
end

return M
