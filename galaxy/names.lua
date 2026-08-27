--- Deterministic name generation for stars and regions.
--
-- Names carry a surprising amount of a 4X map's character, and this map is a
-- hand-drawn atlas: parchment, ink paths, castles and cities. So the
-- vocabulary is grounded rather than astronomical - place-name compounds,
-- people's landings and follies, heraldic beasts - and the catalogue
-- designations, Greek letters and demon mythology that anchored the old
-- space chart are gone with it. Invented words remain, softened, so the map
-- still holds names nobody has read before. Uniqueness is enforced globally
-- so no two systems collide.
--
-- Changing anything here changes every seed's digest: names are hashed
-- (galaxy/digest.lua), so the documented determinism constants are re-baked
-- whenever the vocabulary moves.

local M = {}

-- Invented-word building blocks. Split into onset/nucleus/coda so the results
-- stay pronounceable instead of turning into consonant pileups. The onset list
-- leans on liquids and soft stops; the old chart's "Kh"/"Zh"/"Xi" clusters
-- read as alien, which is now the wrong flavour.
local ONSET = {
	"M", "N", "R", "L", "S", "T", "D", "B", "H", "V", "W", "F", "G", "P",
	"Br", "Tr", "Gl", "St", "Fl", "Gr", "Sw", "Th", "Sh", "Wh", "Cl", "Bl",
	"Mar", "El", "Or", "Al", "Is",
}
-- Simple nuclei are safe after any onset; the diphthongs are only used after a
-- single-consonant onset, because cluster+diphthong pileups are unreadable.
local NUCLEUS_SIMPLE = { "a", "e", "i", "o", "u", "y", "a", "e", "i", "o" }
local NUCLEUS_RICH = {
	"a", "e", "i", "o", "u", "ae", "ai", "ea", "ei", "ia", "io", "ou", "ua",
	"au", "eo",
}
local CODA = {
	"", "", "", "n", "r", "s", "l", "m", "th", "sh", "k", "rn", "ll", "ss",
	"nd", "ng", "st", "z", "tt", "w",
}

-- First elements for place-name compounds: trees, metals, beasts, weather -
-- the things places are actually named after.
local PLACE_STEM = {
	"Ash", "Thorn", "Elder", "Rowan", "Hazel", "Alder", "Bracken", "Heather",
	"Fen", "Stone", "Iron", "Copper", "Silver", "Amber", "Salt", "Frost",
	"Ember", "Winter", "Summer", "Harvest", "Raven", "Crow", "Fox", "Hart",
	"Otter", "Heron", "Mill", "Lantern", "Harrow", "Wander", "Gold", "Moss",
}
-- Second elements. Small and worn, the way real place names end.
local PLACE_SUFFIX = {
	"ford", "mere", "bridge", "haven", "wick", "stead", "gate", "combe",
	"moor", "fell", "march", "field", "brook", "holt", "cross", "well",
	"den", "worth", "ham", "down", "shaw", "leigh",
}
-- People, for possessives: settlers and wanderers, not demons.
local FOLK = {
	"Maren", "Oleta", "Bram", "Wren", "Edda", "Tomas", "Isolde", "Corin",
	"Petra", "Aldous", "Greta", "Ansel", "Mirin", "Odo", "Hesper", "Juno",
	"Casimir", "Vesna", "Rooke", "Sable", "Elowen", "Fable", "Nan", "Piers",
}
-- What a place *is*: kept largely from the old chart, because a Cove or a
-- Folly was always cartography rather than astronomy.
local FEATURES = {
	"Veil", "Gate", "Cove", "Reach", "Rest", "Folly", "Crown", "Wake",
	"Spire", "Deep", "Cradle", "Shadow", "Bastion", "Refuge", "Landing",
	"Passage", "Watch", "Hollow", "Anchorage", "Verge", "Expanse", "Drift",
	"Span", "Hold", "Perch", "Bridge", "Crossing", "Waymeet", "Orchard",
	"Commons", "Harbour", "Garden",
}
local ADJECTIVES = {
	"Swooping", "Burning", "Silent", "Broken", "Golden", "Hollow", "Distant",
	"Frozen", "Shrouded", "Wandering", "Sunken", "Bright", "Fading", "Iron",
	"Amber", "Crimson", "Pale", "Restless", "Sable", "Vermilion",
}
local CREATURES = {
	"Eagle", "Serpent", "Lion", "Kraken", "Hart", "Falcon", "Basilisk", "Wyrm",
	"Mantis", "Leviathan", "Corvid", "Jackal", "Sparrow", "Wolf", "Heron", "Ibis",
}

-- Grand nouns for region names: bigger in scale than a single system's feature.
local REGION_NOUNS = {
	"Maelstrom", "Expanse", "Reach", "Rim", "Verge", "Drift", "Marches",
	"Sprawl", "Deeps", "Frontier", "Dominion", "Fringe", "Shoals", "Wastes",
	"Cradle", "Crown", "Gulf", "Spur", "Belt", "Trace", "Veil", "Vale",
	"Downs", "Weald", "Heath", "Commons",
}
local REGION_ADJECTIVES = {
	"Outer", "Inner", "Wild", "Lost", "Far", "Deep", "Old", "Shattered",
	"Forsaken", "Radiant", "Obsidian", "Umbral", "Argent", "Verdant", "Ashen",
	"Gilded",
}

--- One invented word of 1-3 syllables.
local function invent(r)
	local syllables = r:weighted({ 26, 58, 16 }) -- mostly two syllables
	local parts = {}
	for i = 1, syllables do
		local onset = r:pick(ONSET)
		-- Consonant clusters already carry weight, so keep their vowel simple.
		local nucleus = (#onset > 1) and r:pick(NUCLEUS_SIMPLE) or r:pick(NUCLEUS_RICH)
		local piece = onset .. nucleus
		-- Only the final syllable takes a coda, which avoids "Krant-rk-nd".
		if i == syllables then piece = piece .. r:pick(CODA) end
		parts[#parts + 1] = piece
	end
	local word = table.concat(parts)
	return word:sub(1, 1):upper() .. word:sub(2):lower()
end

local Namer = {}
Namer.__index = Namer

--- Reserve a name, or return nil if it is already taken.
function Namer:claim(name)
	local key = name:lower()
	if self.used[key] then return nil end
	self.used[key] = true
	return name
end

--- Generate one system name via weighted templates.
function Namer:system()
	local r = self.r
	for attempt = 1, 40 do
		local t = r:weighted({
			30, -- place compound: Thornmere, Saltcombe
			16, -- possessive feature: Wren's Crossing
			14, -- stem + feature: Raven Hollow
			14, -- bare invented word
			10, -- adjective creature: Golden Hart
			8,  -- invented possessive: Belwyn's Rest
			8,  -- The + feature: The Waymeet
		})
		local name
		if t == 1 then
			name = r:pick(PLACE_STEM) .. r:pick(PLACE_SUFFIX)
		elseif t == 2 then
			name = r:pick(FOLK) .. "'s " .. r:pick(FEATURES)
		elseif t == 3 then
			name = r:pick(PLACE_STEM) .. " " .. r:pick(FEATURES)
		elseif t == 4 then
			name = invent(r)
		elseif t == 5 then
			name = r:pick(ADJECTIVES) .. " " .. r:pick(CREATURES)
		elseif t == 6 then
			name = invent(r) .. "'s " .. r:pick(FEATURES)
		else
			name = "The " .. r:pick(FEATURES)
		end

		-- After a few collisions stop retrying blind and disambiguate instead,
		-- so a large galaxy cannot stall on an exhausted template.
		if attempt > 12 then
			name = name .. " " .. r:pick(FEATURES)
		end
		local claimed = self:claim(name)
		if claimed then return claimed end
	end
	self.fallback = self.fallback + 1
	return self:claim(invent(self.r) .. string.format(" %d", self.fallback))
		or string.format("Unnamed %d", self.fallback)
end

--- Generate one region name. Rendered uppercase by the map, so kept in title
--- case here and left to the presentation layer.
function Namer:region()
	local r = self.r
	for attempt = 1, 40 do
		local t = r:weighted({ 30, 22, 18, 16, 14 })
		local name
		if t == 1 or t == 2 then
			local adj, noun = r:pick(REGION_ADJECTIVES), r:pick(REGION_NOUNS)
			-- Reject overlaps like "The Deep Deeps".
			if adj:lower():sub(1, 4) == noun:lower():sub(1, 4) then
				noun = r:pick(REGION_NOUNS)
			end
			name = (t == 1 and "The " or "") .. adj .. " " .. noun
		elseif t == 3 then
			name = invent(r) .. " " .. r:pick(REGION_NOUNS)
		elseif t == 4 then
			name = r:pick(PLACE_STEM) .. r:pick(PLACE_SUFFIX) .. " " .. r:pick(REGION_NOUNS)
		else
			name = "The " .. r:pick(REGION_NOUNS) .. " of " .. invent(r)
		end
		if attempt > 12 then name = "Far " .. name end
		local claimed = self:claim(name)
		if claimed then return claimed end
	end
	self.fallback = self.fallback + 1
	return "Province " .. self.fallback
end

--- A namer with its own uniqueness set. Region names are drawn before system
--- names by convention, so the memorable vocabulary lands on regions.
function M.new(r)
	return setmetatable({ r = r, used = {}, fallback = 0 }, Namer)
end

return M
