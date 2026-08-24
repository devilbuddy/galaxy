--- Commanders: the named officer leading a force, and how they improve.
--
-- A fleet in `state.fleets` is a commander *and* the ships they lead - one
-- record, because in this game the two never exist apart. The commander is what
-- makes it worth keeping track of: a force with a name, a rank and a history is
-- something a player is attached to, and losing one is meant to sting in a way
-- that losing twenty ships does not.
--
-- **The cap is the point.** A player may field only `rules.commander_cap` of
-- them, so "which fronts am I fighting on" is a decision rather than a
-- consequence of how many garrisons happened to have ships in them. It is the
-- same reasoning that made fleets deliberate rather than automatic (see
-- galaxy/sim/state.lua) taken one step further.
--
-- Everything here is derived from `level`, so the only thing state has to carry
-- is a level and an experience total.

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
-- ones take a campaign. Experience is measured in enemy ships destroyed, which
-- is a number the player can see on the battle report and reason about.
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

--- Ships this commander can lead. Anything beyond it stays behind.
function M.command(commander, mods)
	local level = commander.level or 1
	local base = rules.command_base + rules.command_per_level * (level - 1)
	return floor(base * ((mods and mods.command) or 1))
end

--- World units covered per turn.
--
-- Deliberately below a typical lane length at level 1, so a green commander
-- spends turns *in transit* and can be caught there. That is the whole reason
-- interception exists, and at the old flat speed nothing was ever slow enough
-- to be caught.
function M.speed(commander, mods)
	local level = commander.level or 1
	local base = rules.commander_speed + rules.speed_per_level * (level - 1)
	return base * ((mods and mods.speed_scale) or 1)
end

--- Multiplier this commander's presence applies in battle.
function M.tactics(commander, mods)
	local level = commander.level or 1
	return (1 + rules.tactics_per_level * (level - 1)) * ((mods and mods.tactics) or 1)
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
		command = M.command(commander, mods),
		speed = M.speed(commander, mods),
		tactics = M.tactics(commander, mods),
	}
end

return M
