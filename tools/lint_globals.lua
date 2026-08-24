-- Finds reads of globals that are almost certainly typos.
--
-- Written because one slipped through everything else. `main/galaxy.script` had
-- `build_dust(seed, world)` where `seed` was never a local - it had been a
-- global read of nil since the first commit. Nothing caught it: the code
-- compiles, `rng.stream(nil, ...)` politely falls back to zero, and the dust
-- rendered, so the only symptom was that the starfield backdrop was byte
-- identical for every galaxy in the game. The editor's language server found it
-- eventually; this makes it a check that runs.
--
-- The trick is to ask LuaJIT rather than to pattern-match the source. Its
-- bytecode listing emits a GGET opcode for every global *read*, naming it, so
-- this is exact where a regex would guess. Writes are ignored on purpose: a
-- Defold script legitimately assigns `init`, `update`, `on_input` and friends
-- as globals.
--
-- Run: luajit tools/lint_globals.lua

-- Everything a file in this project may legitimately reach for. Lua's own
-- standard library, Defold's script API, the engine extensions actually in use,
-- and the two globals a standalone `luajit tools/...` run gets.
local ALLOWED = {}
for name in ([[
	_G _VERSION assert collectgarbage error getmetatable ipairs load loadfile
	loadstring next pairs pcall print rawequal rawget rawlen rawset require
	select setmetatable tonumber tostring type unpack xpcall
	bit coroutine debug io jit math os package string table
	buffer camera crash defos graphics go gui hash html5 http image json label
	liveupdate model msg particlefx physics profiler render resource socket
	sound sprite sys tilemap timer vmath window zlib
	safearea
	arg
]]):gmatch("%S+") do
	ALLOWED[name] = true
end

local DIRS = { "galaxy", "main", "server", "tools" }
local EXTENSIONS = {
	["lua"] = true, ["script"] = true, ["gui_script"] = true,
	["render_script"] = true,
}

local problems = 0

local function check(path)
	-- -b compiles, -l lists; together they never execute the file.
	local pipe = io.popen(string.format("luajit -bl %q 2>&1", path))
	if not pipe then return end
	local output = pipe:read("*a")
	local ok = pipe:close()
	if not ok then
		problems = problems + 1
		print(string.format("%s: will not compile\n    %s",
			path, (output:gsub("%s+$", ""))))
		return
	end

	local seen = {}
	for line in output:gmatch("[^\n]+") do
		local name = line:match('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
		if name and not ALLOWED[name] and not seen[name] then
			seen[name] = true
			problems = problems + 1
			local at = line:match("^%s*(%d+)") or "?"
			print(string.format("%s:%d: reads global `%s` - a typo, or a local that went missing",
				path, tonumber(at) or 0, name))
		end
	end
end

local checked = 0
for _, dir in ipairs(DIRS) do
	local pipe = io.popen("find " .. dir .. " -type f 2>/dev/null | sort")
	if pipe then
		for path in pipe:lines() do
			local ext = path:match("%.([%w_]+)$")
			if ext and EXTENSIONS[ext] then
				check(path)
				checked = checked + 1
			end
		end
		pipe:close()
	end
end

if problems == 0 then
	print(string.format("lint_globals: clean (%d files, no stray global reads)", checked))
	os.exit(0)
end
print(string.format("\nlint_globals: %d problem(s)", problems))
os.exit(1)
