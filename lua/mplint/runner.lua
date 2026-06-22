-- Core linting engine.
--
-- Provides two complementary analysis passes:
-- -- Static heuristics that inspect MetaPost source code without executing
--    the compiler.
-- -- Compiler log parsing that converts MetaPost error messages into
--    structured diagnostics suitable for Neovim.

local M = {}

local function rtrim(s) return (s:gsub('%s+$', '')) end

local function strip_comments_outside_strings(s)
  local out = {}
  local in_str = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_str = not in_str
      out[#out + 1] = c
    elseif c == '%' and not in_str then
      break
    else
      out[#out + 1] = c
    end
  end
  return table.concat(out)
end

local function count_semis_outside_strings(s)
  local n = 0
  local in_str = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_str = not in_str
    elseif not in_str and c == ';' then
      n = n + 1
    end
  end
  return n
end

local function ends_with_semicolon_outside_strings(s)
  s = rtrim(s)
  local last = ''
  local in_str = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_str = not in_str
    elseif not in_str and not c:match '%s' then
      last = c
    end
  end
  return last == ';'
end

local function find_last_unmatched_for(src)
  local stack = {}
  local function strip_for_scan(s)
    local out = {}
    local in_str = false
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == '"' then
        in_str = not in_str
      elseif c == '%' and not in_str then
        break
      else
        out[#out + 1] = c
      end
    end
    return table.concat(out)
  end
  for i = 1, #src do
    local line = strip_for_scan(src[i])
    if line:find '%f[%a]forsuffixes%f[^%w_]' or line:find '%f[%a]for%f[^%w_]' or line:find '%f[%a]forever%f[^%w_]' then stack[#stack + 1] = i end
    if line:find '%f[%a]endfor%f[^%w_]' and #stack > 0 then stack[#stack] = nil end
  end
  return stack[#stack] or 0
end

--- Run static analysis heuristics on the source code to flag common MetaPost syntax issues.
--- This checks for missing semicolons, improper use of `=` instead of `:=` for assignments,
--- unclosed string literals, and matches structural block depths (such as balancing `if...fi`
--- and `begingroup...endgroup` pairs) using internal state stacks.
--- @param src string[] The raw lines of source code to analyze.
--- @return MplintIssue[] issues A list of flagged style issues and syntax warnings.
function M.run_heuristics(src)
  local issues = {}
  local function emit_warning(ln, msg) table.insert(issues, { lnum = ln, col = 1, severity = 'WARN', message = msg }) end

  local allowed_eol = { 'endfor', 'fi', 'endgroup', 'end', 'endfig', 'begingroup', 'etex', 'verbatimtex', '}', ':', '=' }
  local function is_allowed_eol(flat)
    for _, tok in ipairs(allowed_eol) do
      if #flat >= #tok and flat:sub(#flat - #tok + 1) == tok then return true end
    end
    return false
  end

  for ln, raw in ipairs(src) do
    local no_comm = strip_comments_outside_strings(raw)
    if no_comm:match '^%s*\\' then
      if ends_with_semicolon_outside_strings(no_comm) then emit_warning(ln, '(Invalid) TeX preamble line ends with semicolon') end
    else
      local trimmed = rtrim(no_comm)
      local starts_def = trimmed:match '^%s*def%f[%W]'
        or trimmed:match '^%s*vardef%f[%W]'
        or trimmed:match '^%s*primarydef%f[%W]'
        or trimmed:match '^%s*secondarydef%f[%W]'
        or trimmed:match '^%s*tertiarydef%f[%W]'
      local starts_fig_or_char = trimmed:match '^%s*beginfig%s*%b()' or trimmed:match '^%s*beginchar%s*%b()'

      if not (starts_def and trimmed:sub(-1) == '=') and not starts_fig_or_char then
        if no_comm:match '^%s*outputtemplate' then
          local n = count_semis_outside_strings(no_comm)
          if n == 0 or not ends_with_semicolon_outside_strings(no_comm) then emit_warning(ln, '(Possibly) Missing semicolon') end
        else
          local flat = no_comm:gsub('%s+', '')
          if flat ~= '' then
            local n = count_semis_outside_strings(no_comm)
            local allowed = is_allowed_eol(flat)
            if n == 0 and not allowed then
              emit_warning(ln, '(Possibly) Missing semicolon')
            elseif n > 0 and not ends_with_semicolon_outside_strings(no_comm) and not allowed then
              emit_warning(ln, '(Possibly) Missing semicolon')
            end
          end
        end
      end
    end
  end

  local msg_unbalanced = 'Unbalanced block: expected closing token'
  local msg_closing = 'Unexpected closing token'
  local msg_unclosed_v = 'Unclosed verbatimtex ... etex block'
  local msg_unclosed_b = 'Unclosed btex ... etex block'
  local msg_unclosed_q = 'Unclosed string literal'
  local msg_assign = 'Remember to use := for assignment (found =)'

  local BEGINFIG, BEGING, DEF, IFSTK, FOR = {}, {}, {}, {}, {}
  local PAREN, BRACE, BRACK = {}, {}, {}
  local in_verbatim, in_btex = false, false

  local function push(t, v) t[#t + 1] = v end
  local function pop(t)
    local v = t[#t]
    t[#t] = nil
    return v
  end

  local function process_token(tok, ln)
    if in_verbatim then
      if tok == 'etex' then in_verbatim = false end
      return
    end
    if in_btex then
      if tok == 'etex' then in_btex = false end
      return
    end
    if tok == 'verbatimtex' then
      in_verbatim = true
      return
    end
    if tok == 'btex' then
      in_btex = true
      return
    end

    if tok == 'beginfig' then
      push(BEGINFIG, ln)
      return
    end
    if tok == 'endfig' then
      if not pop(BEGINFIG) then emit_warning(ln, msg_closing .. ' (endfig)') end
      return
    end
    if tok == 'begingroup' then
      push(BEGING, ln)
      return
    end
    if tok == 'endgroup' then
      if not pop(BEGING) then emit_warning(ln, msg_closing .. ' (endgroup)') end
      return
    end
    if tok == 'def' or tok == 'vardef' then
      push(DEF, ln)
      return
    end
    if tok == 'enddef' then
      if not pop(DEF) then emit_warning(ln, msg_closing .. ' (enddef)') end
      return
    end
    if tok == 'if' then
      push(IFSTK, ln)
      return
    end
    if tok == 'fi' then
      if not pop(IFSTK) then emit_warning(ln, msg_closing .. ' (fi)') end
      return
    end
    if tok == 'for' or tok == 'forsuffixes' or tok == 'forever' then
      push(FOR, ln)
      return
    end
    if tok == 'endfor' then
      if not pop(FOR) then emit_warning(ln, msg_closing .. ' (endfor)') end
      return
    end

    if tok == '(' then
      push(PAREN, ln)
      return
    end
    if tok == ')' then
      if not pop(PAREN) then emit_warning(ln, msg_closing .. ' ())') end
      return
    end
    if tok == '{' then
      push(BRACE, ln)
      return
    end
    if tok == '}' then
      if not pop(BRACE) then emit_warning(ln, msg_closing .. ' (})') end
      return
    end
    if tok == '[' then
      push(BRACK, ln)
      return
    end
    if tok == ']' then
      if not pop(BRACK) then emit_warning(ln, msg_closing .. ' (])') end
      return
    end
  end

  local function scan_tokens(line, ln)
    local in_str, token = false, nil
    for i = 1, #line do
      local c = line:sub(i, i)
      if not in_str and c == '%' then break end
      if c == '"' then
        in_str = not in_str
        token = nil
      elseif not in_str then
        if c:match '[A-Za-z_\\]' or (token and c:match '%d') then
          token = (token and (token .. c)) or c
        else
          if token then
            process_token(token, ln)
            token = nil
          end
          if c:match '[%(%){%}%[%]]' then process_token(c, ln) end
        end
      end
    end
    if token then process_token(token, ln) end
  end

  for ln, raw in ipairs(src) do
    local only_quotes = raw:gsub('[^"]', '')
    if (#only_quotes % 2) == 1 then emit_warning(ln, msg_unclosed_q) end

    scan_tokens(raw, ln)

    local nocmt = strip_comments_outside_strings(raw)
    local lhs = '^%s*[%a_][%w_]*%s*=%s*'
    local rhs_num = nocmt:match(lhs .. '%-?[%d%.]+%s*')
    local rhs_str = nocmt:match(lhs .. '"[^"]*"%s*')
    local rhs_paren = nocmt:match(lhs .. '%b()%s*')
    if (rhs_num or rhs_str or rhs_paren) and nocmt:match ';%s*$' then emit_warning(ln, msg_assign) end
  end

  local drain = function(stack, tag)
    while #stack > 0 do
      local ln = pop(stack)
      emit_warning(ln, msg_unbalanced .. ' (' .. tag .. ')')
    end
  end

  drain(BEGINFIG, 'beginfig')
  drain(BEGING, 'begingroup')
  drain(DEF, 'def/vardef')
  drain(IFSTK, 'if')
  drain(FOR, 'for')
  drain(PAREN, '())')
  drain(BRACE, '(})')
  drain(BRACK, '(])')

  if in_verbatim then emit_warning(#src, msg_unclosed_v) end
  if in_btex then emit_warning(#src, msg_unclosed_b) end

  return issues
end

--- Parse MetaPost compiler stdout/log line sequences to build a list of structured code anomalies.
--- This implements a stateful state machine that matches error flags (`!`), tracks line number definitions (`l.<num>`),
--- and uses context fallbacks (`find_last_unmatched_for`) when dealing with un-anchored runaway blocks.
--- @param log_lines string[] Raw string sequences captured straight from the compiler's output `.log` files.
--- @param src string[] The full array of source code lines (used to track down lines for runaway errors).
--- @return MplintIssue[] issues A collection of consolidated and parsed issues containing line locations and diagnostics.
function M.parse_log(log_lines, src)
  local issues = {}
  local pending_msg, have_lnum, saw_runaway = nil, false, false
  for _, line in ipairs(log_lines) do
    if line:match '^Runaway' then
      saw_runaway = true
    elseif line:match '^!' then
      if pending_msg and not have_lnum and saw_runaway then
        local ln = find_last_unmatched_for(src)
        table.insert(issues, { lnum = ln == 0 and #src or ln, col = 1, severity = 'ERROR', message = pending_msg })
        saw_runaway = false
      end
      pending_msg = line:gsub('^!%s*', '')
      have_lnum = false
    elseif line:match '^l%.%d+' then
      if pending_msg then
        local ln = tonumber(line:match '^l%.(%d+)') or 1
        table.insert(issues, { lnum = ln, col = 1, severity = 'ERROR', message = pending_msg })
        pending_msg = nil
        have_lnum = true
        saw_runaway = false
      end
    end
  end

  if pending_msg and not have_lnum then
    local ln = saw_runaway and find_last_unmatched_for(src) or 1
    table.insert(issues, { lnum = ln == 0 and #src or ln, col = 1, severity = 'ERROR', message = pending_msg })
  end

  return issues
end

return M
