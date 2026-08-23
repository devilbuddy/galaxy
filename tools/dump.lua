-- Dump generated map data as JSON for the offline preview renderer.
-- Run with: luajit tools/dump.lua <seed> [out.json]
package.path = "./?.lua;" .. package.path

local function esc(s)
	return (s:gsub('["\\]', '\\%0'))
end

local function tojson(v, out)
	local t = type(v)
	if t == "number" then
		out[#out + 1] = string.format("%.6g", v)
	elseif t == "string" then
		out[#out + 1] = '"' .. esc(v) .. '"'
	elseif t == "boolean" then
		out[#out + 1] = tostring(v)
	elseif t == "nil" then
		out[#out + 1] = "null"
	elseif t == "table" then
		if v[1] ~= nil or next(v) == nil then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then out[#out + 1] = "," end
				tojson(v[i], out)
			end
			out[#out + 1] = "]"
		else
			-- Sort keys so the dump itself is byte-stable across runs.
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = k end
			table.sort(keys)
			out[#out + 1] = "{"
			for i = 1, #keys do
				if i > 1 then out[#out + 1] = "," end
				out[#out + 1] = '"' .. esc(tostring(keys[i])) .. '":'
				tojson(v[keys[i]], out)
			end
			out[#out + 1] = "}"
		end
	end
	return out
end

return { tojson = function(v) return table.concat(tojson(v, {})) end }
