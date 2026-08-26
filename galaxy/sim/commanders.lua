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
local races = require("galaxy.sim.races")
local units = require("galaxy.sim.units")

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

-- Portraits per race in main/portraits.atlas. The set is grouped by species -
-- see tools/import_portraits.py - so a Vorn officer is a crimson devil and an
-- Ashai one is green, which is most of what makes a race feel like a people
-- rather than a modifier bundle.
--
-- Twelve rather than one per surname: six races would be 240 images, and a
-- player currently raises exactly one officer. It is enough that a full table
-- never repeats a face; past it the index wraps.
local PORTRAITS_PER_RACE = 12

--- The portrait that goes with an officer's number and their empire's race.
--
-- Indexed by the same counter as the surname, so Kess always has Kess's face -
-- and, because the counter is per player and never re-used, two officers in one
-- empire never look alike until it wraps. The client resolves this to an image
-- in main/portraits.atlas; the simulation only ever deals in the id.
--
-- An unknown race falls back to the default rather than returning nil: a state
-- written before a race existed, or a client sending a typo, must not leave an
-- officer with no face.
function M.portrait(number, name, race)
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
	return string.format("portrait_%s_%02d",
		races.by_id(race).id, ((n - 1) % PORTRAITS_PER_RACE) + 1)
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

--- What the officer is worth on their own, with nothing bought.
--
-- Where a captain starts, and where a broken one reforms. Rank raises it, which
-- is why a veteran is worth having before a single unit is loaded aboard.
function M.base_strength(commander, mods)
	local level = commander.level or 1
	local base = rules.captain_strength
		+ rules.strength_per_level * (level - 1)
	return floor(base * ((mods and mods.attack) or 1) + 0.5)
end

--- How many bought units they can lead on top of that.
function M.max_units(commander, mods)
	local level = commander.level or 1
	local units = rules.captain_units + rules.units_per_level * (level - 1)
	if mods and (mods.attack or 1) > 1 then units = units + 1 end
	return units
end

--- What the officer and their hold are worth against one half of a resistance.
--
-- `against` is `units.FORTIFICATION` or `units.FLEET`. The officer's own worth
-- counts towards both - rank is rank, whatever it is pointed at - and the hold
-- is weighted by type, which is the whole of composition.
--
-- This is the number on the sheet, and the number the player adds up
-- themselves before committing. Every term in it is a small integer for that
-- reason.
function M.power(commander, mods, against)
	return M.base_strength(commander, mods)
		+ units.power(commander.units, against)
end

--- Damage the officer's own command absorbs each exchange before the hold does.
--
-- Only ever reduces losses, never the outcome, so a veteran wins the same
-- fights and comes out of them stronger without making the sheet's arithmetic
-- a lie.
function M.shield(commander)
	return floor((commander.level or 1) / rules.shield_per_levels)
end

--- How many units are aboard.
function M.carried(commander)
	return units.count(commander.units)
end

--- The most strength a captain can hold: their own, plus a full complement.
--
-- **Rank does not cap what a captain carries.** It used to - the ceiling was
-- the rank base alone - and that walled the game shut: a fresh captain could
-- not cover a defended colony, so could not win the battle that would have
-- promoted them, so never got any stronger. Every game stalled with two players
-- on three of the four regions they needed and full purses they could not
-- spend.
--
-- A whole number, for the same reason `steps` is - the player is expected to do
-- this arithmetic themselves before committing to an attack, and half a point
-- of strength is not something anyone can hold in their head.
--- Room left in the hold.
function M.room(commander, mods)
	local room = M.max_units(commander, mods) - M.carried(commander)
	if room < 0 then return 0 end
	return room
end

--- Everything a client needs to draw one, in one call.
function M.profile(commander, mods, race)
	local level = commander.level or 1
	return {
		level = level,
		rank = M.rank(level),
		portrait = M.portrait(commander.number, commander.name, race),
		xp = commander.xp or 0,
		next_xp = (level < rules.commander_max_level)
			and M.xp_for_level(level + 1) or nil,
		steps = M.steps(commander, mods),
		base_strength = M.base_strength(commander, mods),
		-- The two numbers the sheet compares against a target's two halves.
		siege_power = M.power(commander, mods, units.FORTIFICATION),
		fleet_power = M.power(commander, mods, units.FLEET),
		shield = M.shield(commander),
		hold = commander.units,
		carried = M.carried(commander),
		max_units = M.max_units(commander, mods),
	}
end

return M
