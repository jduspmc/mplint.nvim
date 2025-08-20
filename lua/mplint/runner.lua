-- TODO change columns to avoid arror stacking. Also add option to make single error or all errors (nonstopmode or exit on error mode)
-- Runs *inside* Neovim (`nvim -l runner.lua <file.mp>`).
-- Prints diagnostics to STDERR in: file:line:col: Severity: message
-- Exit code: 1 if any diagnostics, 0 otherwise.

local file = arg[#arg]
if not file or file == '' then
  io.stderr:write('stdin:1:1: Error: Missing file argument\n')
  os.exit(2)
end

-- ---------- utils ----------
local function read_lines(path)
  local t, f = {}, io.open(path, 'r')
  if not f then return t end
  for line in f:lines() do
    -- normalize CRLF to LF
    line = line:gsub('\r$', '')
    table.insert(t, line)
  end
  f:close()
  return t
end

local function rtrim(s) return (s:gsub('%s+$','')) end
local function first_nonspace_col(s) local i = s:find('%S'); return i or 1 end
local function last_nonspace_col(s)
  for i = #s, 1, -1 do
    if not s:sub(i,i):match('%s') then return i end
  end
  return 1
end

local function strip_comments_outside_strings(s)
  local out, in_str = {}, false
  for i = 1, #s do
    local c = s:sub(i,i)
    if c == '"' then
      in_str = not in_str
      table.insert(out, c)
    elseif c == '%' and not in_str then
      break
    else
      table.insert(out, c)
    end
  end
  return table.concat(out)
end

local function count_semis_outside_strings(s)
  local n, in_str = 0, false
  for i = 1, #s do
    local c = s:sub(i,i)
    if c == '"' then in_str = not in_str
    elseif not in_str and c == ';' then n = n + 1 end
  end
  return n
end

local function ends_with_semicolon_outside_strings(s)
  s = rtrim(s)
  local last, in_str = '', false
  for i = 1, #s do
    local c = s:sub(i,i)
    if c == '"' then in_str = not in_str
    elseif not in_str and not c:match('%s') then last = c end
  end
  return last == ';'
end

local function first_token(fragment)
  fragment = fragment:gsub('^%s+', '')
  local a = fragment:match('^([^ %t;:,%(%){%}%[%]]+)')
  return a or fragment
end

-- For runaway “for” loops: find last unmatched for/forsuffixes
local function find_last_unmatched_for(src)
  local stack = {}
  local function push(i) stack[#stack+1] = i end
  local function pop() stack[#stack] = nil end

  local function strip_for_scan(s)
    local out, in_str = {}, false
    for i = 1, #s do
      local c = s:sub(i,i)
      if c == '"' then in_str = not in_str
      elseif c == '%' and not in_str then break
      else table.insert(out, c) end
    end
    return table.concat(out)
  end

  for i = 1, #src do
    local line = strip_for_scan(src[i])
    if line:find('%f[%a]forsuffixes%f[^%w_]') or line:find('%f[%a]for%f[^%w_]') then push(i) end
    if line:find('%f[%a]endfor%f[^%w_]') and #stack > 0 then pop() end
  end
  return stack[#stack] or 0
end

-- ---------- run mpost ----------
local function run_mpost(path)
  if vim and vim.system then
    vim.system({ 'mpost', '-interaction=nonstopmode', path }):wait()
  else
    -- fallback if run with stock Lua (rare when used via nvim-lint)
    os.execute(('mpost -interaction=nonstopmode %q'):format(path))
  end
end

-- ---------- PASS 1: parse .log ----------
local src = read_lines(file)
run_mpost(file)
local log = file:gsub('%.mp$', '') .. '.log'
local log_lines = read_lines(log)

local diags = {}

local function emit(sev, f, ln, col, msg)
  diags[#diags+1] = string.format('%s:%d:%d: %s: %s', f, ln, col, sev, msg)
end

do
  local pending_msg = nil
  local have_lnum = false
  local saw_runaway = false

  for _, line in ipairs(log_lines) do
    if line:match('^Runaway') then
      saw_runaway = true

    elseif line:match('^!') then
      -- Only flush previous pending message if we were in a runaway episode and never got l.<n>
      if pending_msg and not have_lnum and saw_runaway then
        local ln = find_last_unmatched_for(src)
        if ln == 0 then ln = #src end
        local col = src[ln] and last_nonspace_col(src[ln]) or 1
        emit('Error', file, ln, col, pending_msg)
        saw_runaway = false
      end

      local cur = line:gsub('^!%s*', '')
      if cur:match('^Emergency stop%.') then
        pending_msg, have_lnum = nil, false
      else
        pending_msg, have_lnum = cur, false
      end

    elseif line:match('^l%.%d+') then
      if pending_msg then
        local ln = tonumber(line:match('^l%.(%d+)')) or 1
        local frag = line:gsub('^l%.%d+%s*', '')
        local tok = first_token(frag)
        local col = 1
        local src_line = src[ln] or ''
        if tok ~= '' then
          local s = src_line:find(tok, 1, true)
          col = s and s or first_nonspace_col(src_line)
        else
          col = first_nonspace_col(src_line)
        end
        emit('Error', file, ln, col, pending_msg)
        pending_msg, have_lnum, saw_runaway = nil, true, false
      end
    end
  end

  -- EOF flush only for runaway with no l.<n>
  if pending_msg and not have_lnum and saw_runaway then
    local ln = find_last_unmatched_for(src)
    if ln == 0 then ln = #src end
    local col = src[ln] and last_nonspace_col(src[ln]) or 1
    emit('Error', file, ln, col, pending_msg)
  end
end

-- ---------- PASS 2: semicolon/preamble (Warnings) ----------
do
  local allow_pat = '([=]|endfor|fi|endgroup|end|endfig|begingroup|etex|verbatimtex|}|:)$'
  local msg_missing   = '(Possibly) Missing semicolon'
  local msg_misplaced = '(Possibly) Misplaced semicolon'
  local msg_preamble  = '(Invalid) TeX preamble line ends with semicolon'

  for ln, raw in ipairs(src) do
    local no_comm = strip_comments_outside_strings(raw)

    -- TeX preamble lines must NOT end with ;
    if no_comm:match('^%s*\\') then
      if ends_with_semicolon_outside_strings(no_comm) then
        emit('Warning', file, ln, last_nonspace_col(no_comm), msg_preamble)
      end
    else
      -- outputtemplate must end with ;
      if no_comm:match('^%s*outputtemplate') then
        local n = count_semis_outside_strings(no_comm)
        if n == 0 or not ends_with_semicolon_outside_strings(no_comm) then
          emit('Warning', file, ln, last_nonspace_col(no_comm), msg_missing)
        end
      else
        local flat = no_comm:gsub('%s+', '')
        if flat ~= '' then
          local n = count_semis_outside_strings(no_comm)
          local is_allowed = flat:match(allow_pat) ~= nil
          local col = last_nonspace_col(no_comm)

          if n == 0 then
            if not is_allowed then
              emit('Warning', file, ln, col, msg_missing)
            end
          else
            if not ends_with_semicolon_outside_strings(no_comm) and not is_allowed then
              emit('Warning', file, ln, col, msg_missing)
            elseif is_allowed and ends_with_semicolon_outside_strings(no_comm) then
              emit('Warning', file, ln, col, msg_misplaced)
            end
          end
        end
      end
    end
  end
end

-- ---------- PASS 3: structure checks (Warnings) ----------
do
  local msg_unbalanced = '(Possibly) Unbalanced block: expected closing token'
  local msg_closing    = '(Possibly) Unexpected closing token'
  local msg_unclosed_v = '(Possibly) Unclosed verbatimtex ... etex block'
  local msg_unclosed_b = '(Possibly) Unclosed btex ... etex block'
  local msg_unclosed_q = '(Possibly) Unclosed string literal'
  local msg_assign     = '(Possibly) Use := for assignment (found =)'

  local BEGINFIG, BEGING, DEF, IFSTK, FOR = {}, {}, {}, {}, {}
  local PAREN, BRACE, BRACK = {}, {}, {}
  local in_verbatim, in_btex = false, false

  local function push(t, v) t[#t+1] = v end
  local function pop(t) local v=t[#t]; t[#t]=nil; return v end

  local function process_token(tok, ln, col)
    if in_verbatim   then if tok == 'etex' then in_verbatim=false end; return end
    if in_btex       then if tok == 'etex' then in_btex=false   end; return end
    if tok == 'verbatimtex' then in_verbatim = true; return end
    if tok == 'btex'       then in_btex     = true; return end

    if tok == 'beginfig'   then push(BEGINFIG, {ln,col}); return end
    if tok == 'endfig'     then if not pop(BEGINFIG) then emit('Warning', file, ln, col, msg_closing .. ' (endfig)') end; return end

    if tok == 'begingroup' then push(BEGING, {ln,col}); return end
    if tok == 'endgroup'   then if not pop(BEGING) then emit('Warning', file, ln, col, msg_closing .. ' (endgroup)') end; return end

    if tok == 'def' or tok == 'vardef' then push(DEF, {ln,col}); return end
    if tok == 'enddef'               then if not pop(DEF) then emit('Warning', file, ln, col, msg_closing .. ' (enddef)') end; return end

    if tok == 'if'   then push(IFSTK, {ln,col}); return end
    if tok == 'fi'   then if not pop(IFSTK) then emit('Warning', file, ln, col, msg_closing .. ' (fi)') end; return end

    if tok == 'for' or tok == 'forsuffixes' then push(FOR, {ln,col}); return end
    if tok == 'endfor' then if not pop(FOR) then emit('Warning', file, ln, col, msg_closing .. ' (endfor)') end; return end

    if tok == '(' then push(PAREN, {ln,col}); return end
    if tok == ')' then if not pop(PAREN) then emit('Warning', file, ln, col, msg_closing .. ' ())') end; return end
    if tok == '{' then push(BRACE, {ln,col}); return end
    if tok == '}' then if not pop(BRACE) then emit('Warning', file, ln, col, msg_closing .. ' (})') end; return end
    if tok == '[' then push(BRACK, {ln,col}); return end
    if tok == ']' then if not pop(BRACK) then emit('Warning', file, ln, col, msg_closing .. ' (])') end; return end
  end

  local function scan_tokens(line, ln)
    local in_str = false
    local token, start = nil, 0
    for i = 1, #line do
      local c = line:sub(i,i)
      if not in_str and c == '%' then break end
      if c == '"' then
        in_str = not in_str
        token, start = nil, 0
      elseif in_str then
        -- skip
      else
        if c:match('[A-Za-z_\\]') or (token and c:match('%d')) then
          if not token then start = i; token = c else token = token .. c end
        else
          if token then process_token(token, ln, start); token, start = nil, 0 end
          if c:match('[%(%){%}%[%]]') then process_token(c, ln, i) end
        end
      end
    end
    if token then process_token(token, ln, start) end
  end

  for ln, raw in ipairs(src) do
    -- 1) unclosed quote per line
    local only_quotes = raw:gsub('[^"]','')
    if (#only_quotes % 2) == 1 then
      emit('Warning', file, ln, last_nonspace_col(raw), msg_unclosed_q)
    end

    -- 2) token scan
    scan_tokens(raw, ln)

    -- 3) assignment heuristic: simple id on LHS, '=', simple literal RHS, and ends with ';'
    local nocmt = raw:gsub('%s*%%.*$', '')
    if nocmt:match('^%s*[%a_][%w_]*%s*=%s*(%-?[%d%.]+%s*|"%b"%'..'s*|%b())') and nocmt:match(';%s*$') then
      emit('Warning', file, ln, last_nonspace_col(raw), msg_assign)
    end
  end

  local function drain(stack, tag)
    while #stack > 0 do
      local loc = pop(stack)
      emit('Warning', file, loc[1], loc[2], msg_unbalanced .. ' ('..tag..')')
    end
  end

  drain(BEGINFIG, 'beginfig')
  drain(BEGING,   'begingroup')
  drain(DEF,      'def/vardef')
  drain(IFSTK,    'if')
  drain(FOR,      'for')
  drain(PAREN,    '())')
  drain(BRACE,    '(})')
  drain(BRACK,    '(])')

  if in_verbatim then emit('Warning', file, #src, 1, msg_unclosed_v) end
  if in_btex     then emit('Warning', file, #src, 1, msg_unclosed_b) end
end

-- ---------- print & exit ----------
if #diags > 0 then
  for _, d in ipairs(diags) do io.stderr:write(d .. '\n') end
  os.exit(1)
else
  os.exit(0)
end
