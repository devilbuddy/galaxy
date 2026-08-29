-- Rebuilding the past from the event log.
--
-- The client is never told who held what forty turns ago - the server keeps one
-- current record and nothing else - so the playback winds today's ownership
-- backwards through the digest. That is either exactly right or quietly wrong,
-- and an animation is the worst possible place to find out which.
--
-- So the test plays a real game, snapshots who owned what at the start of every
-- turn as it goes, and then checks the reconstruction against those snapshots.
--
-- Run: luajit tools/test_playback.lua

package.path = "./?.lua;" .. package.path

local gen = require("realm.generate")
local st = require("realm.sim.state")
local res = require("realm.sim.resolve")
local path = require("realm.sim.path")
local view = require("realm.sim.view")
local bots = require("realm.sim.bots")
local races = require("realm.sim.races")
local playback = require("main.playback")

local SEED = 1337
local REALM = gen.build(SEED)
-- Long enough to contain a war. Dwellings gate production now, so the first
-- fight of a four-player game lands a little past turn 30 - and a fixture with
-- no battle in it silently stops testing the half of the rewind that reads
-- `battle` events.
local TURNS = 45

local failures = 0
local function check(name, ok, detail)
	if ok then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
	end
end

local function new_game(count)
	local ids = races.ids()
	local players = {}
	for i = 1, count do
		players[i] = { id = "p" .. i, name = "P" .. i,
			race = ids[((i - 1) % #ids) + 1], bot = i > 1 or nil }
	end
	return st.new(REALM, players)
end

local function snapshot(state)
	local out = {}
	for id, sys in pairs(state.tiles) do out[id] = sys.owner end
	return out
end

--- Play a game, keeping every turn's opening ownership and all its events.
local function play(state)
	local opening, events = {}, {}
	for _ = 1, TURNS do
		opening[state.turn + 1] = snapshot(state)
		local produced = res.turn(REALM, state, bots.all_orders(REALM, state))
		for i = 1, #produced do events[#events + 1] = produced[i] end
	end
	return opening, events
end

print("the past, wound back from today")
do
	local state = new_game(4)
	local opening, events = play(state)

	-- Everything, unfogged: the reconstruction has to be exact before it is
	-- asked to cope with a player who only saw half of it.
	local tiles = {}
	for id, sys in pairs(state.tiles) do
		tiles[tostring(id)] = { owner = sys.owner }
	end

	local steps, final = playback.build({ events = events, you = 1 }, tiles)
	check("a step per turn that produced anything", #steps > 0, #steps)

	local wrong, checked = nil, 0
	for i = 1, #steps do
		local step = steps[i]
		local truth = opening[step.turn]
		if truth then
			for id, who in pairs(truth) do
				checked = checked + 1
				if (step.owners[id] or 0) ~= who then
					wrong = string.format("turn %d tile %d: rebuilt %s, was %s",
						step.turn, id, tostring(step.owners[id]), tostring(who))
					break
				end
			end
		end
		if wrong then break end
	end
	check("every turn opens on exactly the map it opened on", wrong == nil, wrong)
	check("and that is a real check, not an empty loop", checked > 1000, checked)

	local drift = nil
	for id, sys in pairs(state.tiles) do
		if (final[id] or 0) ~= sys.owner then drift = id break end
	end
	check("and playing it all the way through lands on today", drift == nil, drift)
end

print("what the turn produced")
do
	local state = new_game(4)
	local _, events = play(state)
	local tiles = {}
	for id, sys in pairs(state.tiles) do tiles[tostring(id)] = { owner = sys.owner } end
	local steps = playback.build({ events = events, you = 1 }, tiles)

	local moves, battles, changes, quiet = 0, 0, 0, 0
	for i = 1, #steps do
		moves = moves + #steps[i].moves
		battles = battles + #steps[i].battles
		changes = changes + #steps[i].changes
		if steps[i].quiet then quiet = quiet + 1 end
	end
	check("marches are carried, with the tiles they crossed", moves > 0, moves)
	check("so are the fights", battles > 0, battles)
	check("and every ownership change, in the order it happened", changes > 0, changes)
	check("a change names who it was taken from", (function()
		for i = 1, #steps do
			for k = 1, #steps[i].changes do
				local c = steps[i].changes[k]
				if c.battle and (c.from or 0) == 0 then return false end
			end
		end
		return true
	end)())
	check("a quiet turn is held for less time", (function()
		local q = { quiet = true, battles = {}, moves = {} }
		local busy = { quiet = false, battles = { {} }, moves = {} }
		return playback.duration(q) < playback.duration(busy)
	end)())
	check("every move has somewhere to start and somewhere to go", (function()
		for i = 1, #steps do
			for k = 1, #steps[i].moves do
				local m = steps[i].moves[k]
				if not m.from or #m.path == 0 then return false end
			end
		end
		return true
	end)())
end

print("a battle, unwound")
do
	local units = require("realm.sim.units")
	-- Play until a real battle turns up, so the shape under test is one the
	-- resolver actually produces rather than one written to suit the test.
	local state = new_game(4)
	local battle
	for _ = 1, 120 do
		local produced = res.turn(REALM, state,
			bots.all_orders(REALM, state))
		for i = 1, #produced do
			if produced[i].kind == "battle" and #produced[i].exchanges > 1
				and not battle then
				battle = produced[i]
			end
		end
		if battle then break end
	end
	check("a battle with more than one exchange happens", battle ~= nil)

	local frames = playback.battle(battle, units.CATALOGUE)
	check("a frame per exchange", #frames == #battle.exchanges,
		#frames .. " vs " .. #battle.exchanges)

	-- The last frame minus its own losses has to be what the commander came out
	-- with, or the rewind has drifted.
	local last = frames[#frames]
	local ends = {}
	for i = 1, #units.CATALOGUE do
		local id = units.CATALOGUE[i].id
		ends[id] = last.hold[id] - (last.lost[id] or 0)
	end
	local drift = nil
	for i = 1, #units.CATALOGUE do
		local id = units.CATALOGUE[i].id
		if ends[id] ~= (battle.hold[id] or 0) then drift = id end
	end
	check("winding back through the losses lands on the hold it ended with",
		drift == nil, drift)

	check("and it only ever thins out", (function()
		for e = 2, #frames do
			for i = 1, #units.CATALOGUE do
				local id = units.CATALOGUE[i].id
				if frames[e].hold[id] > frames[e - 1].hold[id] then return false end
			end
		end
		return true
	end)())

	check("the first frame is what went in", (function()
		local went_in = 0
		for i = 1, #units.CATALOGUE do
			went_in = went_in + frames[1].hold[units.CATALOGUE[i].id]
		end
		local lost = 0
		for _, n in pairs(battle.lost) do lost = lost + n end
		local came_out = 0
		for _, n in pairs(battle.hold) do came_out = came_out + n end
		return went_in == lost + came_out
	end)(), "went in should be lost + came out")

	check("an event with no exchanges yields no frames",
		#playback.battle({}, units.CATALOGUE) == 0)

	-- The hold on the event has to be a snapshot. It used to be the commander's
	-- live table, so a commander that marched on and loaded at a city before
	-- the turn was serialised left the battle reporting the hold it ended the
	-- *turn* with - and the screen unwound its exchanges from the wrong end.
	check("the hold on the event is a snapshot, not the commander's own table",
		(function()
			local before = 0
			for _, n in pairs(battle.hold) do before = before + n end
			-- Play on. If `hold` were live this would drift.
			for _ = 1, 6 do
				res.turn(REALM, state, bots.all_orders(REALM, state))
			end
			local after = 0
			for _, n in pairs(battle.hold) do after = after + n end
			return before == after
		end)())
end

print("through the fog")
do
	-- What a player is actually handed: their own projection, and only the
	-- events they were allowed to see.
	local state = new_game(4)
	local _, events = play(state)
	local mine = {}
	for i = 1, #events do
		local who = events[i].visible_to or {}
		for k = 1, #who do
			if who[k] == 1 then mine[#mine + 1] = events[i] break end
		end
	end
	local v = view.project(REALM, state, 1)

	local ok, steps = pcall(playback.build, { events = mine, you = 1 }, v.tiles)
	check("a fogged digest builds a timeline", ok, steps)
	if ok then
		check("shorter than the whole war", #mine < #events, #mine .. " of " .. #events)
		local bad = nil
		for i = 1, #steps do
			for id, who in pairs(steps[i].owners) do
				if type(id) ~= "number" or type(who) ~= "number" then bad = id end
			end
		end
		check("and every tile in it is a number holding a number", bad == nil, bad)
	end
end

if failures > 0 then
	print(string.format("\n%d PLAYBACK TEST(S) FAILED", failures))
	os.exit(1)
end
print("\nALL PLAYBACK TESTS PASSED")
