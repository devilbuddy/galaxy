--- Getting at screens that are otherwise hard to reach.
--
-- Two of this game's screens are **one-shot by design**, and that is a problem
-- for looking at them rather than for playing:
--
--   * a turn digest marks itself read the moment it is opened (`main/seen.lua`),
--     so the playback that was worth watching cannot be watched twice;
--   * a battle screen needs a battle, which needs a fight worth having, which
--     needs an army, a target and several turns of economy first.
--
-- So this is the back door. **Debug builds only** - `sys.get_engine_info()` says
-- which, the same gate the automation bridge uses, so none of it reaches a
-- release build or costs anything in one.
--
-- Deliberately a module rather than a few lines in the lobby: it is the thing
-- most likely to be deleted wholesale one day, and it should come out in one
-- piece when it is.

local units = require("realm.sim.units")

local M = {}

local is_debug = nil

--- Is this a build where the back door should exist at all?
function M.enabled()
	if is_debug == nil then
		local info = sys.get_engine_info and sys.get_engine_info()
		is_debug = (info and info.is_debug) and true or false
	end
	return is_debug
end

--- A battle worth looking at, built from the real catalogue.
--
-- Hand-written rather than resolved, because producing one for real means
-- generating a realm, opening a game and playing until somebody defends
-- something - which is exactly the friction this exists to get around.
--
-- The numbers are self-consistent on purpose: what went in equals what was lost
-- plus what came out, so `playback.battle` unwinds it exactly the way it
-- unwinds a real one and the screen is exercising its actual arithmetic rather
-- than being handed a picture.
--
--   went in   6 Line, 2 Lance, 2 Siege
--   lost      5 Line, 1 Lance
--   came out  1 Line, 1 Lance, 2 Siege
function M.sample_battle()
	return {
		kind = "battle", turn = 47, at = 1,
		player = 1, against = 2,
		name = "Kess", rank = "Commodore", level = 5,
		-- Both halves beaten, which is why there was a battle at all.
		fortification = 17, army = 12,
		siege = 24, army_power = 20,
		garrison = {
			{ commander = 9, name = "Vantor", rank = "Commander", power = 12 },
		},
		exchanges = {
			{ lost = { escort = 3 }, shield = 2 },
			{ lost = { escort = 2, interceptor = 1 }, shield = 2 },
			{ lost = {}, shield = 2 },
		},
		lost = units.normalise({ escort = 5, interceptor = 1 }),
		hold = units.normalise({ escort = 1, interceptor = 1, bombard = 2 }),
	}
end

return M
