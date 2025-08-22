-- lua/mplint/formatter.lua
-- Simple MetaPost formatter:
-- - Indent inside blocks (beginfig/endfig, begingroup/endgroup, def*/enddef,
--   if/fi, for|forsuffixes/endfor, verbatimtex/etex)
-- - Do NOT indent for single-line blocks (open+close on the same line)
-- - Everything outside blocks -> zero indent
-- - Insert a blank line before an opening block and after a closing block
--
-- Public API:
--   require('mplint.formatter').format_lines(lines, { indent_width = 2 })
--   require('mplint.formatter').format({ buf = 0, indent_width = 2 })

local F = {}

local function ltrim(s)
	return (s:gsub("^%s+", ""))
end

local function rtrim(s)
	return (s:gsub("%s+$", ""))
end

-- Remove % comments (outside quotes) and ignore content after '%'.
-- Keep a plain string (no quotes toggling content) only for scanning tokens.
local function strip_for_scan(s)
	local out, in_str = {}, false
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == '"' then
			in_str = not in_str
		-- do not include quotes into out; we only need words
		elseif c == "%" and not in_str then
			break
		else
			if not in_str then
				out[#out + 1] = c
			end
		end
	end
	return table.concat(out)
end

local function is_blank(s)
	return s:match("^%s*$") ~= nil
end

-- Token mapping to "groups" so different spellings share the same stack key.
-- opens[group] = set of opening words
-- closes[word] = group it closes
local opens_by_word = {
	beginfig = "beginfig",
	begingroup = "begingroup",
	def = "def",
	vardef = "def",
	primarydef = "def",
	secondarydef = "def",
	tertiarydef = "def",
	["if"] = "if",
	["for"] = "for",
	forsuffixes = "for",
	verbatimtex = "verbatim",
}
local closes_to_group = {
	endfig = "beginfig",
	endgroup = "begingroup",
	enddef = "def",
	fi = "if",
	endfor = "for",
	etex = "verbatim",
}

-- Scan a sanitized line into a list of token records in order.
-- Returns { {kind="open"|"close", group="...", word="..."} , ... }
local function scan_tokens_in_line(line_sanitized)
	local toks = {}
	for word in line_sanitized:gmatch("%a+") do
		if opens_by_word[word] then
			toks[#toks + 1] = { kind = "open", group = opens_by_word[word], word = word }
		elseif closes_to_group[word] then
			toks[#toks + 1] = { kind = "close", group = closes_to_group[word], word = word }
		end
	end
	return toks
end

-- For a single line, compute:
--   starts_with_close: does the trimmed line begin with an unmatched closing?
--   opens_unmatched:   number of opening groups that remain open across lines
--   closes_unmatched:  number of closing groups that close previously-open blocks
local function line_block_delta(raw_line)
	local trimmed = ltrim(raw_line)
	if trimmed == "" then
		return false, 0, 0
	end
	local s = strip_for_scan(raw_line)
	local toks = scan_tokens_in_line(s)

	local line_stack = {}
	local closes_unmatched = 0
	local starts_with_close = false

	local first_seen = toks[1] and toks[1].kind or nil
	if first_seen == "close" then
		-- Might pair with an 'open' later on the same line; we decide after walking.
		starts_with_close = true
	end

	for _, tk in ipairs(toks) do
		if tk.kind == "open" then
			table.insert(line_stack, tk.group)
		-- if later a matching close appears on this same line, it will pop
		else
			-- close: if top of line_stack matches, it's a single-line pair; pop
			if #line_stack > 0 and line_stack[#line_stack] == tk.group then
				table.remove(line_stack)
				-- if the *first* token was a close but we paired it with an open on the same line,
				-- then it's not an unmatched close at line start.
				if starts_with_close and first_seen == "close" then
					starts_with_close = false
				end
			else
				-- unmatched close (applies to an outer block)
				closes_unmatched = closes_unmatched + 1
			end
		end
	end

	local opens_unmatched = #line_stack
	-- refine starts_with_close: it only matters if there is at least one unmatched close
	if starts_with_close and closes_unmatched == 0 then
		starts_with_close = false
	end

	return starts_with_close, opens_unmatched, closes_unmatched
end

-- Enforce a blank line before an opening block and after a closing block.
-- We insert exactly one blank line (not two in a row).
local function maybe_insert_blank_before(out_lines)
	if #out_lines == 0 then
		return
	end
	if not is_blank(out_lines[#out_lines]) then
		table.insert(out_lines, "")
	end
end

local function maybe_insert_blank_after_peek(out_lines, next_input_line)
	if is_blank(next_input_line or "") then
		return
	end
	if not is_blank(out_lines[#out_lines] or "") then
		table.insert(out_lines, "")
	end
end

-- Core: format an array of lines
function F.format_lines(lines, opts)
	opts = opts or {}
	local indent_width = tonumber(opts.indent_width) or 2
	local INDENT = string.rep(" ", indent_width)

	local out = {}
	local depth = 0

	for i = 1, #lines do
		local raw = lines[i]
		local next_line = lines[i + 1]
		local starts_with_close, opens_unmatched, closes_unmatched = line_block_delta(raw)

		local trimmed = ltrim(raw)
		-- Decide indent for this line:
		--   - Blank lines: keep empty
		--   - If line starts with a closing token -> dedent by one (but not below 0)
		--   - Else indent according to current depth
		local line_depth = depth
		if starts_with_close then
			line_depth = math.max(0, depth - 1)
		end

		-- If this line introduces blocks that remain open after this line,
		-- ensure a blank line *before* it (unless already blank or at top).
		if opens_unmatched > 0 then
			-- Edge case: if it's also a closing line at the start, we still consider it an opener (rare).
			maybe_insert_blank_before(out)
		end

		if is_blank(trimmed) then
			table.insert(out, "")
		else
			-- Normalize leading indentation: everything outside blocks is zero indent,
			-- inside blocks gets (depth) * indent_width spaces.
			local content = ltrim(raw)
			local prefix = (line_depth > 0) and string.rep(INDENT, line_depth) or ""
			table.insert(out, prefix .. rtrim(content))
		end

		-- Update running depth AFTER formatting the current line:
		--   depth += unmatched_opens - unmatched_closes
		depth = depth + opens_unmatched - closes_unmatched
		if depth < 0 then
			depth = 0
		end

		-- If this line closes a block (unmatched close), ensure a blank line *after* it,
		-- unless the next input line is already blank or we're at EOF.
		if closes_unmatched > 0 then
			maybe_insert_blank_after_peek(out, next_line)
		end
	end

	-- Ensure depth ends non-negative (it should); we don't try to auto-fix unbalanced here.
	return out
end

-- Format current buffer (or a given buffer)
function F.format(opts)
	opts = opts or {}
	local bufnr = opts.buf or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local new_lines = F.format_lines(lines, opts)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

return F
