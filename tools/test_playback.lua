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

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local path = require("galaxy.sim.path")
local view = require("galaxy.sim.view")
local bots = require("galaxy.sim.bots")
local races = require("galaxy.sim.races")
local playback = require("main.playback")

local SEED = 1337
local GALAXY = gen.build(SEED)
local LENGTHS = path.lane_lengths(GALAXY)
local TURNS = 30

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
	return st.new(GALAXY, players)
end

local function snapshot(state)
	local out = {}
	for id, sys in pairs(state.systems) do out[id] = sys.owner end
	return out
end

--- Play a game, keeping every turn's opening ownership and all its events.
local function play(state)
	local opening, events = {}, {}
	for _ = 1, TURNS do
		opening[state.turn + 1] = snapshot(state)
		local produced = res.turn(GALAXY, state, bots.all_orders(GALAXY, state), LENGTHS)
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
	local systems = {}
	for id, sys in pairs(state.systems) do
		systems[tostring(id)] = { owner = sys.owner }
	end

	local steps, final = playback.build({ events = events, you = 1 }, systems)
	check("a step per turn that produced anything", #steps > 0, #steps)

	local wrong, checked = nil, 0
	for i = 1, #steps do
		local step = steps[i]
		local truth = opening[step.turn]
		if truth then
			for id, who in pairs(truth) do
				checked = checked + 1
				if (step.owners[id] or 0) ~= who then
					wrong = string.format("turn %d system %d: rebuilt %s, was %s",
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
	for id, sys in pairs(state.systems) do
		if (final[id] or 0) ~= sys.owner then drift = id break end
	end
	check("and playing it all the way through lands on today", drift == nil, drift)
end

print("what the turn produced")
do
	local state = new_game(4)
	local _, events = play(state)
	local systems = {}
	for id, sys in pairs(state.systems) do systems[tostring(id)] = { owner = sys.owner } end
	local steps = playback.build({ events = events, you = 1 }, systems)

	local moves, battles, changes, quiet = 0, 0, 0, 0
	for i = 1, #steps do
		moves = moves + #steps[i].moves
		battles = battles + #steps[i].battles
		changes = changes + #steps[i].changes
		if steps[i].quiet then quiet = quiet + 1 end
	end
	check("marches are carried, with the lanes they crossed", moves > 0, moves)
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
	local v = view.project(GALAXY, state, 1)

	local ok, steps = pcall(playback.build, { events = mine, you = 1 }, v.systems)
	check("a fogged digest builds a timeline", ok, steps)
	if ok then
		check("shorter than the whole war", #mine < #events, #mine .. " of " .. #events)
		local bad = nil
		for i = 1, #steps do
			for id, who in pairs(steps[i].owners) do
				if type(id) ~= "number" or type(who) ~= "number" then bad = id end
			end
		end
		check("and every system in it is a number holding a number", bad == nil, bad)
	end
end

if failures > 0 then
	print(string.format("\n%d PLAYBACK TEST(S) FAILED", failures))
	os.exit(1)
end
print("\nALL PLAYBACK TESTS PASSED")
