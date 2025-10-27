-- formatter.lua (module: mplint.formatter)
local M = {}

local DEFAULTS = {
	indent_width = 4,
	blank_lines = true,
}

-- Block delimiters (leading-space-tolerant, line-anchored)
local START_PATS = {
	"^%s*primarydef%f[%W]",
	"^%s*secondarydef%f[%W]",
	"^%s*tertiarydef%f[%W]",
	"^%s*vardef%f[%W]",
	"^%s*def%f[%W]",
	"^%s*for%f[%W]",
	"^%s*forsuffixes%f[%W]",
	"^%s*forever%f[%W]",
	"^%s*verbatimtex%f[%W]",
	"^%s*beginfig%s*%b()",
	"^%s*if%f[%W]",
	"^%s*begingroup%f[%W]", -- NEW
}

local END_PATS = {
	"^%s*enddef%s*;?%s*$",
	"^%s*endfor%s*;?%s*$",
	"^%s*etex%s*;?%s*$",
	"^%s*endfig%s*;?%s*$",
	"^%s*fi%s*;?%s*$",
	"^%s*endgroup%s*;?%s*$", -- NEW
}

local function matches_any(line, pats)
	for _, p in ipairs(pats) do
		if line:match(p) then
			return true
		end
	end
	return false
end

-- detect single-line blocks: line has a starter and any matching closer
local function looks_single_line_block(l)
	if not matches_any(l, START_PATS) then
		return false
	end
	if
		l:find("%f[%a]enddef%f[^%w_]")
		or l:find("%f[%a]endfor%f[^%w_]")
		or l:find("%f[%a]fi%f[^%w_]")
		or l:find("%f[%a]etex%f[^%w_]")
		or l:find("%f[%a]endfig%f[^%w_]")
		or l:find("%f[%a]endgroup%f[^%w_]")
	then -- NEW
		return true
	end
	return false
end

local function is_blank(s)
	return s:match("^%s*$") ~= nil
end
local function rstrip(s)
	return (s:gsub("[ \t]+$", ""))
end

local function split_lines(text)
	local out = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(out, line)
	end
	return out
end

local function join_lines(lines)
	return table.concat(lines, "\n") .. "\n"
end
local function ensure_blank_before(out)
	if #out > 0 and out[#out] ~= "" then
		table.insert(out, "")
	end
end

local function collapse_blank_runs(lines)
	local out, last_blank = {}, false
	for _, l in ipairs(lines) do
		local b = is_blank(l)
		if b then
			if not last_blank then
				table.insert(out, "")
			end
			last_blank = true
		else
			table.insert(out, l)
			last_blank = false
		end
	end
	return out
end

--- Format a MetaPost source string.
--- @param text string
--- @param opts table|nil { indent_width: number, blank_lines: boolean }
function M.format_text(text, opts)
	opts = opts or {}
	local indent_width = tonumber(opts.indent_width or DEFAULTS.indent_width) or 4
	local blank_lines = (opts.blank_lines ~= nil) and opts.blank_lines or DEFAULTS.blank_lines
	local INDENT = string.rep(" ", indent_width)

	local src = split_lines(text)

	-- 1) trim trailing whitespace
	for i = 1, #src do
		src[i] = rstrip(src[i])
	end

	-- 2) structure-aware indentation + spacing
	local out, level = {}, 0

	for i = 1, #src do
		local line = src[i]
		local is_end = matches_any(line, END_PATS)
		local is_start = matches_any(line, START_PATS)
		local single_line = is_start and looks_single_line_block(line)

		if not single_line and is_end then
			-- outdent BEFORE printing end-lines
			level = math.max(0, level - 1)
		end

		if blank_lines and is_start then
			ensure_blank_before(out) -- blank line before block starts
		end

		if is_blank(line) then
			table.insert(out, "")
		else
			local normalized = (line:gsub("^%s*", ""))
			table.insert(out, (INDENT:rep(level)) .. normalized) -- only indent inside blocks
		end

		if is_start and not single_line then
			level = level + 1 -- increase after multi-line starts
		end

		if blank_lines and (is_end or single_line) then
			table.insert(out, "") -- blank after block ends or single-line blocks
		end
	end

	out = collapse_blank_runs(out)
	while #out > 0 and out[1] == "" do
		table.remove(out, 1)
	end
	while #out > 0 and out[#out] == "" do
		table.remove(out, #out)
	end

	return join_lines(out)
end

--- Format the current buffer in Neovim.
--- @param opts table|nil same as format_text
--- @param bufnr integer|nil default: current buffer
function M.format_buffer(opts, bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local text = table.concat(lines, "\n")
	local formatted = M.format_text(text, opts or {})
	local out_lines = split_lines(formatted)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out_lines)
end

return M
