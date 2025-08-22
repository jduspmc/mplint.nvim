-- Runs `nvim -l runner.lua <file.mp>`.
-- Emits: file:line:1: Severity: message

local file = arg[#arg]
if not file or file == "" then
	io.stderr:write("stdin:1:1: Error: Missing file argument\n")
	os.exit(2)
end

-- mode flag from init.lua
local mode = "nonstop"
for i = 1, #arg - 1 do
	if arg[i] == "--mplint-halt" then
		mode = "halt"
	end
	if arg[i] == "--mplint-nonstop" then
		mode = "nonstop"
	end
end

-- ------------ aux functions ------------
local function read_lines(path)
	local t, f = {}, io.open(path, "r")
	if not f then
		return t
	end
	for line in f:lines() do
		t[#t + 1] = (line:gsub("\r$", ""))
	end
	f:close()
	return t
end

local function rtrim(s)
	return (s:gsub("%s+$", ""))
end

-- strip % comments but keep content inside double quotes
local function strip_comments_outside_strings(s)
	local out, in_str = {}, false
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == '"' then
			in_str = not in_str
			out[#out + 1] = c
		elseif c == "%" and not in_str then
			break
		else
			out[#out + 1] = c
		end
	end
	return table.concat(out)
end

local function count_semis_outside_strings(s)
	local n, in_str = 0, false
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == '"' then
			in_str = not in_str
		elseif not in_str and c == ";" then
			n = n + 1
		end
	end
	return n
end

local function ends_with_semicolon_outside_strings(s)
	s = rtrim(s)
	local last, in_str = "", false
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == '"' then
			in_str = not in_str
		elseif not in_str and not c:match("%s") then
			last = c
		end
	end
	return last == ";"
end

-- find last unmatched 'for' / 'forsuffixes' (for runaway loops)
local function find_last_unmatched_for(src)
	local stack = {}
	local function strip_for_scan(s)
		local out, in_str = {}, false
		for i = 1, #s do
			local c = s:sub(i, i)
			if c == '"' then
				in_str = not in_str
			elseif c == "%" and not in_str then
				break
			else
				out[#out + 1] = c
			end
		end
		return table.concat(out)
	end
	for i = 1, #src do
		local line = strip_for_scan(src[i])
		if line:find("%f[%a]forsuffixes%f[^%w_]") or line:find("%f[%a]for%f[^%w_]") then
			stack[#stack + 1] = i
		end
		if line:find("%f[%a]endfor%f[^%w_]") and #stack > 0 then
			stack[#stack] = nil
		end
	end
	return stack[#stack] or 0
end

-- ------------ run mpost (vim.system only) ------------
local function run_mpost(path)
	local flag = (mode == "halt") and "--halt-on-error" or "--interaction=nonstopmode"
	local res = vim.system({ "mpost", flag, path }, { text = true }):wait()
	-- If mpost isn't found, libuv spawn fails; Neovim returns code 127 on *nix.
	if not res or res.code == 127 then
		io.stderr:write(string.format("%s:1:1: Error: mpost not found in PATH\n", file))
		os.exit(2)
	end
	-- Non-zero exit is fine in halt mode; we read the .log next either way.
end

-- ------------ PASS 1: parse .log (Errors) ------------
local src = read_lines(file)
run_mpost(file)
local log = (file:gsub("%.[Mm][Pp]$", "")) .. ".log" -- case-insensitive
local log_lines = read_lines(log)

if #log_lines == 0 then
	io.stderr:write(string.format("%s:1:1: Error: MetaPost produced no .log (compile failed?)\n", file))
	os.exit(2)
end

local diags = {}
local function emit(sev, f, ln, _, msg)
	diags[#diags + 1] = string.format("%s:%d:1: %s: %s", f, ln, sev, msg)
end

do
	local pending_msg, have_lnum, saw_runaway = nil, false, false
	local i = 1
	while i <= #log_lines do
		local line = log_lines[i]

		if line:match("^Runaway") then
			saw_runaway = true
		elseif line:match("^!") then
			-- flush previous only for runaway-without-location
			if pending_msg and not have_lnum and saw_runaway then
				local ln = find_last_unmatched_for(src)
				if ln == 0 then
					ln = #src
				end
				emit("Error", file, ln, 1, pending_msg)
				saw_runaway = false
			end
			pending_msg = line:gsub("^!%s*", "")
			have_lnum = false
			if pending_msg:match("^Emergency stop%.") then
				pending_msg = nil
				have_lnum = false -- ignore generic follow-up
			end
		elseif line:match("^l%.%d+") then
			if pending_msg then
				local ln = tonumber(line:match("^l%.(%d+)")) or 1
				local frag = line:gsub("^l%.%d+%s*", "")
				local frag_trim = frag:gsub("^%s+", "")
				local fullmsg = pending_msg
				if frag_trim ~= "" then
					local nxt = log_lines[i + 1]
					if nxt and nxt ~= "" and not nxt:match("^!") and not nxt:match("^l%.%d+") then
						local nxt_trim = nxt:gsub("^%s+", "")
						fullmsg = string.format("%s %s --> %s", pending_msg, frag_trim, nxt_trim)
					else
						fullmsg = string.format("%s %s", pending_msg, frag_trim)
					end
				end
				emit("Error", file, ln, 1, fullmsg)
				pending_msg = nil
				have_lnum = true
				saw_runaway = false
			end
		end

		i = i + 1
	end

	-- EOF flush only for runaway with no l.<n>
	if pending_msg and not have_lnum and saw_runaway then
		local ln = find_last_unmatched_for(src)
		if ln == 0 then
			ln = #src
		end
		emit("Error", file, ln, 1, pending_msg)
	end
end

-- ------------ PASS 2: semicolon / preamble (Warnings) ------------
do
	-- Tokens that may legitimately end a line without a trailing semicolon
	local allowed_eol = {
		"endfor",
		"fi",
		"endgroup",
		"end",
		"endfig",
		"begingroup",
		"etex",
		"verbatimtex",
		"}",
		":",
	}
	local function is_allowed_eol(flat)
		for _, tok in ipairs(allowed_eol) do
			if #flat >= #tok and flat:sub(#flat - #tok + 1) == tok then
				return true
			end
		end
		return false
	end

	local msg_missing = "(Possibly) Missing semicolon"
	local msg_misplaced = "(Possibly) Misplaced semicolon"
	local msg_preamble = "(Invalid) TeX preamble line ends with semicolon"

	for ln, raw in ipairs(src) do
		local no_comm = strip_comments_outside_strings(raw)

		-- TeX preamble lines must NOT end with ;
		if no_comm:match("^%s*\\") then
			if ends_with_semicolon_outside_strings(no_comm) then
				emit("Warning", file, ln, 1, msg_preamble)
			end
		else
			-- NEW: def/vardef/primarydef/secondarydef/tertiarydef lines ending with '='
			-- are allowed to omit a trailing semicolon
			local trimmed = rtrim(no_comm)
			local starts_def = trimmed:match("^%s*def%f[%W]")
				or trimmed:match("^%s*vardef%f[%W]")
				or trimmed:match("^%s*primarydef%f[%W]")
				or trimmed:match("^%s*secondarydef%f[%W]")
				or trimmed:match("^%s*tertiarydef%f[%W]")

			if starts_def and trimmed:sub(-1) == "=" then
			-- Allowed: no semicolon needed; skip the rest of semicolon checks
			-- (still let other passes catch structural issues)
			else
				-- Special-case: outputtemplate must end with ;
				if no_comm:match("^%s*outputtemplate") then
					local n = count_semis_outside_strings(no_comm)
					if n == 0 or not ends_with_semicolon_outside_strings(no_comm) then
						emit("Warning", file, ln, 1, msg_missing)
					end
				else
					-- General semicolon rules
					local flat = no_comm:gsub("%s+", "")
					if flat ~= "" then
						local n = count_semis_outside_strings(no_comm)
						local allowed = is_allowed_eol(flat)
						if n == 0 then
							if not allowed then
								emit("Warning", file, ln, 1, msg_missing)
							end
						else
							if not ends_with_semicolon_outside_strings(no_comm) and not allowed then
								emit("Warning", file, ln, 1, msg_missing)
							elseif allowed and ends_with_semicolon_outside_strings(no_comm) then
								emit("Warning", file, ln, 1, msg_misplaced)
							end
						end
					end
				end
			end
		end
	end
end

-- ------------ PASS 3: structure checks (Warnings) ------------
do
	local msg_unbalanced = "Unbalanced block: expected closing token"
	local msg_closing = "Unexpected closing token"
	local msg_unclosed_v = "Unclosed verbatimtex ... etex block"
	local msg_unclosed_b = "Unclosed btex ... etex block"
	local msg_unclosed_q = "Unclosed string literal"
	local msg_assign = "Remember to use := for assignment (found =)"

	local BEGINFIG, BEGING, DEF, IFSTK, FOR = {}, {}, {}, {}, {}
	local PAREN, BRACE, BRACK = {}, {}, {}
	local in_verbatim, in_btex = false, false

	local function push(t, v)
		t[#t + 1] = v
	end
	local function pop(t)
		local v = t[#t]
		t[#t] = nil
		return v
	end

	local function process_token(tok, ln)
		if in_verbatim then
			if tok == "etex" then
				in_verbatim = false
			end
			return
		end
		if in_btex then
			if tok == "etex" then
				in_btex = false
			end
			return
		end
		if tok == "verbatimtex" then
			in_verbatim = true
			return
		end
		if tok == "btex" then
			in_btex = true
			return
		end

		if tok == "beginfig" then
			push(BEGINFIG, ln)
			return
		end
		if tok == "endfig" then
			if not pop(BEGINFIG) then
				emit("Warning", file, ln, 1, msg_closing .. " (endfig)")
			end
			return
		end

		if tok == "begingroup" then
			push(BEGING, ln)
			return
		end
		if tok == "endgroup" then
			if not pop(BEGING) then
				emit("Warning", file, ln, 1, msg_closing .. " (endgroup)")
			end
			return
		end

		if tok == "def" or tok == "vardef" then
			push(DEF, ln)
			return
		end
		if tok == "enddef" then
			if not pop(DEF) then
				emit("Warning", file, ln, 1, msg_closing .. " (enddef)")
			end
			return
		end

		if tok == "if" then
			push(IFSTK, ln)
			return
		end
		if tok == "fi" then
			if not pop(IFSTK) then
				emit("Warning", file, ln, 1, msg_closing .. " (fi)")
			end
			return
		end

		if tok == "for" or tok == "forsuffixes" then
			push(FOR, ln)
			return
		end
		if tok == "endfor" then
			if not pop(FOR) then
				emit("Warning", file, ln, 1, msg_closing .. " (endfor)")
			end
			return
		end

		if tok == "(" then
			push(PAREN, ln)
			return
		end
		if tok == ")" then
			if not pop(PAREN) then
				emit("Warning", file, ln, 1, msg_closing .. " ())")
			end
			return
		end
		if tok == "{" then
			push(BRACE, ln)
			return
		end
		if tok == "}" then
			if not pop(BRACE) then
				emit("Warning", file, ln, 1, msg_closing .. " (})")
			end
			return
		end
		if tok == "[" then
			push(BRACK, ln)
			return
		end
		if tok == "]" then
			if not pop(BRACK) then
				emit("Warning", file, ln, 1, msg_closing .. " (])")
			end
			return
		end
	end

	local function scan_tokens(line, ln)
		local in_str, token = false, nil
		for i = 1, #line do
			local c = line:sub(i, i)
			if not in_str and c == "%" then
				break
			end
			if c == '"' then
				in_str = not in_str
				token = nil
			elseif in_str then
			-- skip
			else
				if c:match("[A-Za-z_\\]") or (token and c:match("%d")) then
					token = (token and (token .. c)) or c
				else
					if token then
						process_token(token, ln)
						token = nil
					end
					if c:match("[%(%){%}%[%]]") then
						process_token(c, ln)
					end
				end
			end
		end
		if token then
			process_token(token, ln)
		end
	end

	for ln, raw in ipairs(src) do
		-- unclosed quote on this line
		local only_quotes = raw:gsub('[^"]', "")
		if (#only_quotes % 2) == 1 then
			emit("Warning", file, ln, 1, msg_unclosed_q)
		end

		scan_tokens(raw, ln)

		-- assignment heuristic: LHS id, '=', (number OR "string" OR ( ... )), ends with ';'
		local nocmt = raw:gsub("%s*%%.*$", "")
		local lhs = "^%s*[%a_][%w_]*%s*=%s*"
		local rhs_num = nocmt:match(lhs .. "%-?[%d%.]+%s*")
		local rhs_str = nocmt:match(lhs .. '"[^"]*"%s*')
		local rhs_paren = nocmt:match(lhs .. "%b()%s*")
		if (rhs_num or rhs_str or rhs_paren) and nocmt:match(";%s*$") then
			emit("Warning", file, ln, 1, msg_assign)
		end
	end

	local function drain(stack, tag)
		while #stack > 0 do
			local ln = stack[#stack]
			stack[#stack] = nil
			emit("Warning", file, ln, 1, msg_unbalanced .. " (" .. tag .. ")")
		end
	end

	drain(BEGINFIG, "beginfig")
	drain(BEGING, "begingroup")
	drain(DEF, "def/vardef")
	drain(IFSTK, "if")
	drain(FOR, "for")
	drain(PAREN, "())")
	drain(BRACE, "(})")
	drain(BRACK, "(])")

	if in_verbatim then
		emit("Warning", file, #src, 1, msg_unclosed_v)
	end
	if in_btex then
		emit("Warning", file, #src, 1, msg_unclosed_b)
	end
end

-- ------------ print & exit ------------
if #diags > 0 then
	for _, d in ipairs(diags) do
		io.stderr:write(d .. "\n")
	end
	os.exit(1)
else
	os.exit(0)
end
