--- Captains: the named officer, and how they improve.
--
-- A captain is a named officer who moves on the map. The name and the face are
-- most of the point: a piece a player is attached to is worth more than a token,
-- and every player currently has exactly one.
--
-- Rank, reach and how much a captain can spend taking ground all derive from
-- `level`, so state carries only a level, an experience total and the strength
-- currently left in the field.

local rules = require("galaxy.sim.rules")

local floor = math.floor

local M = {}

-- Rank ------------------------------------------------------------------------

-- Promotion is how a level reads on the map. A number in a list is something a
-- player has to look up; "Admiral Kess" against "Captain Kess" is legible at a
-- glance, and it is the same information.
local RANKS = {
	{ from = 1,  title = "Captain" },
	{ from = 3,  title = "Commander" },
	{ from = 5,  title = "Commodore" },
	{ from = 7,  title = "Admiral" },
	{ from = 9,  title = "Grand Admiral" },
}

--- The rank a commander of this level holds.
function M.rank(level)
	local title = RANKS[1].title
	for i = 1, #RANKS do
		if level >= RANKS[i].from then title = RANKS[i].title end
	end
	return title
end

-- Surnames are invented rather than borrowed, for the same reason system names
-- are: a real one carries associations the game has not earned. Forty is enough
-- that ten players fielding four each rarely collide, and the fallback below
-- handles it when they do.
local SURNAMES = {
	"Kess", "Vantor", "Ilbrecht", "Morrow", "Sable", "Duquette", "Haan",
	"Oyelaran", "Verek", "Castellan", "Nyx", "Ferreira", "Thorne", "Adeyemi",
	"Lindqvist", "Bassari", "Okonkwo", "Reyes", "Volkov", "Aurelio",
	"Maddox", "Sorensen", "Ghazal", "Petrakis", "Winter", "Nakamura",
	"Belmonte", "Osei", "Kovac", "Delacroix", "Ashworth", "Rahimi",
	"Sundberg", "Marchetti", "Ivanova", "Bouchard", "Quintero", "Halvorsen",
	"Eriksen", "Zamora",
}

--- The portrait that goes with an officer's number.
--
-- Indexed by the same counter as the surname, so Kess always has Kess's face -
-- and, because the counter is per player and never re-used, two officers in one
-- empire never look alike until it wraps. The client resolves this to an image
-- in main/portraits.atlas; the simulation only ever deals in the id.
--
-- The atlas holds exactly as many portraits as there are surnames. If that ever
-- stops being true this still returns something valid, but the pairing drifts.
function M.portrait(number, name)
	local n = tonumber(number)
	if not n and name then
		-- A commander raised before officers carried a number - or any record
		-- that has been through a JSON round trip that dropped it - is still
		-- identifiable by surname, which is what the number chose in the first
		-- place. Without this fallback every such officer shares one face.
		for i = 1, #SURNAMES do
			if SURNAMES[i] == name then n = i break end
		end
	end
	n = math.max(1, math.floor(n or 1))
	return string.format("portrait_%02d", ((n - 1) % #SURNAMES) + 1)
end

--- A commander's name, drawn deterministically from the player's own counter.
--
-- Indexed rather than rolled so it cannot depend on how many battles have been
-- fought: the nth commander a player raises always has the same name, whatever
-- else happened. `pairs` is never involved, so this is identical on both
-- runtimes.
function M.name(player)
	local n = player.next_commander_number or 1
	player.next_commander_number = n + 1
	local index = ((n - 1) % #SURNAMES) + 1
	local surname = SURNAMES[index]
	-- Past one pass through the list, distinguish by a numeral rather than by
	-- inventing a name that reads as a different person.
	local pass = floor((n - 1) / #SURNAMES)
	if pass > 0 then surname = surname .. " " .. tostring(pass + 1) end
	return surname
end

-- Progression -----------------------------------------------------------------

--- Cumulative experience needed to *reach* this level.
--
-- Quadratic, so early promotions come from a couple of skirmishes and the last
-- ones take a campaign. Experience is the **strength a captain has overcome**,
-- so a colony is worth more than a waypoint without any table having to say so,
-- and it is a number the player watched happen on the turn report.
function M.xp_for_level(level)
	if level <= 1 then return 0 end
	return rules.commander_xp_base * (level - 1) * level
end

--- The level an experience total earns, capped.
function M.level_for_xp(xp)
	local level = 1
	while level < rules.commander_max_level
		and xp >= M.xp_for_level(level + 1) do
		level = level + 1
	end
	return level
end

--- Award experience and return the number of levels gained.
function M.award(commander, xp)
	if xp <= 0 then return 0 end
	commander.xp = (commander.xp or 0) + xp
	local was = commander.level or 1
	local now = M.level_for_xp(commander.xp)
	if now <= was then return 0 end
	commander.level = now
	return now - was
end

--- A defeated commander is broken, not killed.
--
-- Losing an officer outright would make a single bad battle unrecoverable in a
-- game checked twice a day, and would push players towards never committing.
-- Demotion costs the thing that was actually earned - the rank - and the army is
-- gone either way.
function M.demote(commander)
	local level = math.max(1, (commander.level or 1) - 1)
	commander.level = level
	commander.xp = M.xp_for_level(level)
	return level
end

-- Derived stats ---------------------------------------------------------------

--- Lanes crossed per turn.
--
-- A whole number, always. Movement being countable is the whole point: a player
-- can look at a route, count the systems, and know which turn a captain lands.
function M.steps(commander, mods)
	local level = commander.level or 1
	local steps = rules.captain_steps
	for at, bonus in pairs(rules.steps_at_rank) do
		if level >= at then steps = steps + bonus end
	end
	if mods and (mods.step_bonus or 0) > 0 then
		steps = steps + mods.step_bonus
	end
	return steps
end

--- The most strength a captain can hold.
--
-- Rank buys weight as well as reach, which is what makes a veteran able to
-- crack a capital when a fresh officer cannot: `rules.capital_defence` is set
-- above a level-one captain's whole ceiling on purpose.
--
-- A whole number, for the same reason `steps` is - the player is expected to do
-- this arithmetic themselves before committing to an attack, and half a point
-- of strength is not something anyone can hold in their head.
function M.max_strength(commander, mods)
	local level = commander.level or 1
	local base = rules.captain_strength
		+ rules.strength_per_level * (level - 1)
	return floor(base * ((mods and mods.attack) or 1) + 0.5)
end

--- Strength in hand right now, never above the ceiling.
--
-- Clamped on read rather than on write: the ceiling moves when a captain is
-- promoted or demoted, and a value stored under the old one would otherwise
-- read as full when it is not, or sit above full forever.
function M.strength(commander, mods)
	local cap = M.max_strength(commander, mods)
	local have = tonumber(commander.strength)
	if not have then return cap end
	if have > cap then return cap end
	if have < 0 then return 0 end
	return have
end

--- Everything a client needs to draw one, in one call.
function M.profile(commander, mods)
	local level = commander.level or 1
	return {
		level = level,
		rank = M.rank(level),
		portrait = M.portrait(commander.number, commander.name),
		xp = commander.xp or 0,
		next_xp = (level < rules.commander_max_level)
			and M.xp_for_level(level + 1) or nil,
		steps = M.steps(commander, mods),
		strength = M.strength(commander, mods),
		max_strength = M.max_strength(commander, mods),
	}
end

return M
