-- Guards against Lua idioms that Nakama's runtime miscompiles.
--
-- galaxy/ runs on both the Defold client (LuaJIT) and the Nakama server
-- (gopher-lua). The server's runtime evaluates a multiple-assignment swap
-- sequentially rather than simultaneously:
--
--     local a, b = 1, 2
--     a, b = b, a          --> a = 2, b = 2   (should be 2, 1)
--
-- That is silent and produced a corrupt lane graph for a long time before it
-- was traced. Since it cannot be detected at runtime without paying for it on
-- every call, it is banned by lint in the code the server shares.
--
-- `goto` and labels are banned for a related reason: they are Lua 5.2, LuaJIT
-- accepts them happily, and gopher-lua is a 5.1 runtime - so a `goto continue`
-- passes every offline test and is a coin flip on the server. The editor's
-- language server, also configured for 5.1, is the only thing that caught it.
--
-- Run: luajit tools/lint_shared.lua

local DIRS = { "galaxy" }

local problems = 0

local function check(path)
	local f = io.open(path, "r")
	if not f then return end
	local line_no = 0
	for line in f:lines() do
		line_no = line_no + 1
		local code = line:match("^(.-)%-%-") or line

		-- Lua 5.2 control flow. See the header.
		if code:match("%f[%w]goto%f[%W]") or code:match("::%s*[%w_]+%s*::") then
			problems = problems + 1
			print(string.format("%s:%d: goto/label is Lua 5.2; gopher-lua is 5.1\n    %s",
				path, line_no, line:gsub("^%s+", "")))
		end

		-- Two comma-separated targets whose right-hand side is the same two
		-- names in the other order.
		local x, y, p, q = code:match("([%w_%.%[%]]+)%s*,%s*([%w_%.%[%]]+)%s*=%s*([%w_%.%[%]]+)%s*,%s*([%w_%.%[%]]+)%s*$")
		if x and ((x == q and y == p) and x ~= y) then
			problems = problems + 1
			print(string.format("%s:%d: multiple-assignment swap (use an explicit temporary)\n    %s",
				path, line_no, line:gsub("^%s+", "")))
		end
	end
	f:close()
end

-- `find`, not `ls dir/*.lua`: galaxy/sim/ runs on the server too, and a glob
-- that stops at the top level silently exempted the entire simulation from
-- this check.
local checked = 0
for _, dir in ipairs(DIRS) do
	local pipe = io.popen("find " .. dir .. " -name '*.lua' 2>/dev/null | sort")
	if pipe then
		for path in pipe:lines() do
			check(path)
			checked = checked + 1
		end
		pipe:close()
	end
end

if problems == 0 then
	print(string.format("lint_shared: clean (%d files, no swap idioms or Lua 5.2 syntax)",
		checked))
	os.exit(0)
end
print(string.format("\nlint_shared: %d problem(s)", problems))
os.exit(1)
