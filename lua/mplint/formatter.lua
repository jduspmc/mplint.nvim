-- formatter.lua (module: mplint.formatter)
-- This module implements a robust, structure-aware formatter for MetaPost.
-- It cleans up trailing whitespace, indents blocks, handles middle-block boundaries
-- (like else/elseif), and preserves Neovim cursor / window viewport positions.

local M = {}

local DEFAULTS = {
  indent_width = 4,
  blank_lines = false,
}

-- Block delimiters (leading-space-tolerant, line-anchored)
local START_PATS = {
  '^%s*primarydef%f[%W]',
  '^%s*secondarydef%f[%W]',
  '^%s*tertiarydef%f[%W]',
  '^%s*vardef%f[%W]',
  '^%s*def%f[%W]',
  '^%s*for%f[%W]',
  '^%s*forsuffixes%f[%W]',
  '^%s*forever%f[%W]',
  '^%s*verbatimtex%f[%W]',
  '^%s*btex%f[%W]',
  '^%s*beginfig%s*%b()',
  '^%s*beginchar%s*%b()',
  '^%s*if%f[%W]',
  '^%s*begingroup%f[%W]',
}

local END_PATS = {
  '%f[%a]enddef%f[^%w_]%s*;?%s*$',
  '%f[%a]endfor%f[^%w_]%s*;?%s*$',
  '%f[%a]etex%f[^%w_]%s*;?%s*$',
  '%f[%a]endfig%f[^%w_]%s*;?%s*$',
  '%f[%a]endchar%f[^%w_]%s*;?%s*$',
  '%f[%a]fi%f[^%w_]%s*;?%s*$',
  '%f[%a]endgroup%f[^%w_]%s*;?%s*$',
}

-- Control flow structures that exist inside a block (e.g. if ... else ... fi).
-- These lines should temporarily align with the opening and closing delimiters
-- without resetting the block's persistent indentation level.
local MIDDLE_PATS = {
  '^%s*elseif%f[%W]',
  '^%s*else%f[%W]',
}

-- Strips comments and string contents from a line.
-- This ensures the formatter matches syntax structures based on actual code
-- rather than text in comment logs or label strings.
local function clean_tokens(s)
  local out = {}
  local in_str = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_str = not in_str
      out[#out + 1] = '""' -- representation of empty string
    elseif not in_str then
      if c == '%' then
        break -- Stop processing at comment markers
      else
        out[#out + 1] = c
      end
    end
  end
  return table.concat(out)
end

local function matches_any(line, pats)
  for _, p in ipairs(pats) do
    if line:match(p) then return true end
  end
  return false
end

-- Detect single-line blocks (e.g., begingroup ... endgroup on a single line)
-- by confirming the line contains both an opener and a corresponding closer.
local function looks_single_line_block(l)
  if not matches_any(l, START_PATS) then return false end
  if
    l:find '%f[%a]enddef%f[^%w_]'
    or l:find '%f[%a]endfor%f[^%w_]'
    or l:find '%f[%a]fi%f[^%w_]'
    or l:find '%f[%a]etex%f[^%w_]'
    or l:find '%f[%a]endfig%f[^%w_]'
    or l:find '%f[%a]endchar%f[^%w_]'
    or l:find '%f[%a]endgroup%f[^%w_]'
  then
    return true
  end
  return false
end

local function is_blank(s) return s:match '^%s*$' ~= nil end

local function rstrip(s) return (s:gsub('[ \t]+$', '')) end

-- Splitting buffer text into lines while normalizing newlines correctly
local function split_lines(text)
  local out = {}
  local cleaned = text:gsub('\n$', '') -- remove single trailing newline
  for line in (cleaned .. '\n'):gmatch '(.-)\n' do
    table.insert(out, line)
  end
  return out
end

local function join_lines(lines) return table.concat(lines, '\n') .. '\n' end

local function ensure_blank_before(out)
  if #out > 0 and out[#out] ~= '' then table.insert(out, '') end
end

local function collapse_blank_runs(lines)
  local out, last_blank = {}, false
  for _, l in ipairs(lines) do
    local b = is_blank(l)
    if b then
      if not last_blank then table.insert(out, '') end
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
  local blank_lines
  if opts.blank_lines ~= nil then
    blank_lines = opts.blank_lines
  else
    blank_lines = DEFAULTS.blank_lines
  end
  local INDENT = string.rep(' ', indent_width)

  local src = split_lines(text)

  -- Trim trailing whitespaces
  for i = 1, #src do
    src[i] = rstrip(src[i])
  end

  -- Structure-aware indentation and spacing
  local out, level = {}, 0

  for i = 1, #src do
    local line = src[i]
    local clean_line = clean_tokens(line)

    local is_end = matches_any(clean_line, END_PATS)
    local is_start = matches_any(clean_line, START_PATS)
    local is_middle = matches_any(clean_line, MIDDLE_PATS)
    local single_line = is_start and looks_single_line_block(clean_line)

    -- Decide the indentation level of this specific line
    local current_level = level
    if not single_line and is_end then
      level = math.max(0, level - 1)
      current_level = level
    elseif is_middle then
      current_level = math.max(0, level - 1)
    end

    if blank_lines and is_start then
      ensure_blank_before(out) -- Add space before block starts
    end

    if is_blank(line) then
      table.insert(out, '')
    else
      local normalized = (line:gsub('^%s*', ''))
      table.insert(out, (INDENT:rep(current_level)) .. normalized)
    end

    if is_start and not single_line then level = level + 1 end

    if blank_lines and (is_end or single_line) then
      table.insert(out, '') -- Add space after block ends
    end
  end

  -- Remove trailing empty lines and double-blanks
  out = collapse_blank_runs(out)

  while #out > 0 and out[1] == '' do
    table.remove(out, 1)
  end
  while #out > 0 and out[#out] == '' do
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
  local text = table.concat(lines, '\n')
  local formatted = M.format_text(text, opts or {})

  -- Avoid marking the buffer modified if it is already clean
  if text == formatted:gsub('\n$', '') or text .. '\n' == formatted then return end

  local out_lines = split_lines(formatted)

  -- Save cursor position and viewport state to prevent jarring shifts
  local view = vim.fn.winsaveview()

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out_lines)

  -- Restore cursor and viewport position
  vim.fn.winrestview(view)
end

return M
