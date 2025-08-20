local M = {}

function M.setup(opts)
  local lint = require('lint')
  local parser = require('lint.parser')

  -- gfortran-style: file:line:col: Severity: message
  local pattern = '^([^:]+):(%d+):(%d+):%s+([^:]+):%s+(.*)$'
  local groups  = { 'file', 'lnum', 'col', 'severity', 'message' }
  local severity_map = {
    ['Error']   = vim.diagnostic.severity.ERROR,
    ['Warning'] = vim.diagnostic.severity.WARN,
  }

  -- Resolve path to runner.lua in this plugin
  local here = debug.getinfo(1, 'S').source:sub(2)
  local runner = here:gsub('init%.lua$', 'runner.lua')

  -- Filetype for .mp
  vim.filetype.add({ extension = { mp = 'metapost' } })

  -- Register the linter with nvim-lint (spawns Neovim as a Lua runner)
  lint.linters.mplint = {
    name = 'mplint',
    cmd  = 'nvim',
    args = { '-l', runner },
    stdin = false,
    append_fname = true,      -- nvim-lint appends current file path
    stream = 'stderr',
    ignore_exitcode = true,   -- non-zero exit just means “found diagnostics”
    parser = parser.from_pattern(pattern, groups, severity_map, { source = 'mplint' }),
  }

  -- Attach to filetype
  lint.linters_by_ft.metapost = { 'mplint' }
end

return M
