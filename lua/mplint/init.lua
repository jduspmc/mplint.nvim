-- Main entry to plugin.
-- Responsible for configuring mplint, selecting the linting backend,
-- registering autocommands and user commands, and integrating with
-- nvim-lint and conform.nvim.

local M = {}

-- find linter bin
local source = debug.getinfo(1, 'S').source
local current_file_path = source:gsub('^@', ''):gsub('\\', '/')
local plugin_root = current_file_path:match '(.+)/lua/mplint/[^/]+$' or vim.fn.getcwd()
local binary_path = vim.fs.joinpath(plugin_root, 'bin', 'mplint-lint')

---@class MplintOpts Configuration options for the mplint plugin.
---@field linter_backend? "'manual'"|"'nvim-lint'" The engine used to process linting (default: 'manual')
---@field halt_on_error? boolean Stop linting at the very first syntax error (default: false)
---@field filetypes? string[] Target Neovim filetypes to attach the plugin to (default: {'mp'})
---@field events? string[] Neovim autocommand events that trigger the linter (default: {'BufWritePost', 'InsertLeave'})
---@field enabled? boolean Turn the automated linting process on or off (default: true)
---@field tex_engine? string|nil Internal LaTeX/TeX compiler variant to target (default: nil)
---@field indent_width? integer Number of spaces used for block structural indentations (default: 4)
---@field blank_lines? boolean Dynamically inject blank spacing gaps around code blocks (default: false)
---@field preview_enabled? boolean Turn the automated previewer on or off (default: true)
---@field preview_scale? number Default image scaling factor used by the preview window (default: 1)

--- Initialize and configure the mplint plugin environment.
--- Sets up internal state routing, diagnostics autocommands, user commands, and conform.nvim bindings.
--- @param opts? MplintOpts Custom user preferences override table (falls back to defaults if omitted)
function M.setup(opts)
  opts = vim.tbl_deep_extend('force', {
    enabled = true,
    linter_backend = 'manual', -- Options: 'nvim-lint' or 'manual'
    halt_on_error = false,
    events = { 'BufWritePost', 'InsertLeave' },
    filetypes = { 'mp' },
    tex_engine = nil,
    indent_width = 4,
    blank_lines = false,
    preview_enabled = false,
    preview_scale = 1,
  }, opts or {})

  if opts.linter_backend ~= 'manual' and opts.linter_backend ~= 'nvim-lint' then
    error(("mplint: invalid linter_backend '%s'"):format(tostring(opts.linter_backend)))
  end

  local linter = require 'mplint.linter'
  linter.opts.halt_on_error = opts.halt_on_error
  linter.opts.enabled = opts.enabled
  linter.opts.tex_engine = opts.tex_engine

  local previewer = require 'mplint.previewer'
  previewer.opts.enabled = opts.preview_enabled
  previewer.opts.tex_engine = opts.tex_engine
  previewer.opts.scale = opts.preview_scale

  -- Build the filetype set map
  local ft_set = {}
  for _, ft in ipairs(opts.filetypes) do
    ft_set[ft] = true
  end

  ---------------------------------------------------------------------------
  -- Environment Detection & Linter Routing Functions
  ---------------------------------------------------------------------------
  -- check if lint exists
  local has_nvim_lint, nvim_lint = pcall(require, 'lint')

  -- We wrap the nvim-lint definition in a helper function so we can conditionalize it
  local function setup_nvim_lint()
    if has_nvim_lint then
      nvim_lint.linters.mplint = {
        name = 'mplint',
        cmd = 'nvim',
        args = { '-l', binary_path },
        stdin = false,
        append_fname = true,
        stream = 'stderr',
        ignore_exitcode = true,
        env = {
          MPLINT_HALT = 'false',
          MPLINT_TEX = '',
        },
        parser = require('lint.parser').from_pattern('([^:]+):(%d+):(%d+):%s*%[([A-Z]+)%]%s*(.*)', { 'file', 'lnum', 'col', 'severity', 'message' }, {
          ['WARN'] = vim.diagnostic.severity.WARN,
          ['ERROR'] = vim.diagnostic.severity.ERROR,
        }, { source = 'mplint' }),
      }
    end
  end

  local function trigger_lint()
    if not linter.opts.enabled then return end

    local current_ft = vim.api.nvim_get_option_value('filetype', { buf = 0 })
    if not ft_set[current_ft] then return end

    -- ROUTING ENGINE: Choose your testing sandbox
    if opts.linter_backend == 'nvim-lint' and has_nvim_lint then
      -- Sync environment variables right before nvim-lint fires
      local lint_def = nvim_lint.linters.mplint
      if not lint_def then return end
      lint_def.env.MPLINT_HALT = tostring(linter.opts.halt_on_error)
      lint_def.env.MPLINT_TEX = linter.opts.tex_engine or ''

      nvim_lint.try_lint 'mplint'
    else
      -- CUSTOM SANDBOX: Runs your manual linter execution logic completely decoupled from nvim-lint
      if linter.lint then linter.lint() end
    end
  end

  -- Only initialize nvim-lint if the user explicitly wants it as their backend
  if opts.linter_backend == 'nvim-lint' then setup_nvim_lint() end

  ---------------------------------------------------------------------------
  -- Autocommands (Runs seamlessly for BOTH backends via our router)
  ---------------------------------------------------------------------------
  local au_group = vim.api.nvim_create_augroup('MplintEventGroup', { clear = true })
  if #opts.events > 0 then vim.api.nvim_create_autocmd(opts.events, {
    group = au_group,
    callback = trigger_lint,
  }) end

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = au_group,
    callback = function(args)
      local bufnr = args.buf
      pcall(function() require('mplint.linter').cancel(bufnr) end)
      pcall(function() require('mplint.previewer').cancel(bufnr) end)
    end,
  })

  ---------------------------------------------------------------------------
  -- Formatter Integration
  ---------------------------------------------------------------------------
  local has_conform, conform = pcall(require, 'conform')
  if has_conform then
    conform.formatters.mplint = {
      format = function(_, _, lines, callback)
        local text = table.concat(lines, '\n')
        local formatter = require 'mplint.formatter'
        local ok, formatted = pcall(formatter.format_text, text, {
          indent_width = opts.indent_width,
          blank_lines = opts.blank_lines,
        })
        if not ok then
          callback(formatted, nil)
          return
        end

        local out_lines = {}
        for line in (formatted .. '\n'):gmatch '(.-)\r?\n' do
          table.insert(out_lines, line)
        end
        if #out_lines > 0 and out_lines[#out_lines] == '' then table.remove(out_lines) end
        callback(nil, out_lines)
      end,
    }
  end

  local function indent_current_buffer()
    local fmt = require 'mplint.formatter'
    fmt.format_buffer({
      indent_width = opts.indent_width,
      blank_lines = opts.blank_lines,
    }, 0)
    trigger_lint()
  end

  ---------------------------------------------------------------------------
  -- User Commands
  ---------------------------------------------------------------------------
  vim.api.nvim_create_user_command('MplintToggleHalt', function()
    linter.opts.halt_on_error = not linter.opts.halt_on_error
    vim.notify('mplint mode: ' .. (linter.opts.halt_on_error and 'halt-on-error' or 'nonstopmode'), vim.log.levels.INFO)
    trigger_lint()
  end, {})

  vim.api.nvim_create_user_command('MplintToggleLint', function()
    linter.opts.enabled = not linter.opts.enabled
    vim.notify('mplint: ' .. (linter.opts.enabled and 'enabled' or 'disabled'), vim.log.levels.INFO)
    if not linter.opts.enabled then
      require('mplint.ui').clear(0)
    else
      trigger_lint()
    end
  end, {})

  vim.api.nvim_create_user_command('MplintIndent', indent_current_buffer, {
    desc = 'mplint: Format MetaPost buffer',
  })

  if opts.preview_enabled then
    vim.api.nvim_create_user_command('MplintPreview', function(cmd)
      local scale

      if cmd.args ~= '' then
        scale = tonumber(cmd.args)
        if not scale then
          vim.notify('mplint: Scale must be a number.', vim.log.levels.ERROR)
          return
        end
      end

      previewer.preview {
        scale = scale,
      }
    end, {
      nargs = '?',
      desc = 'mplint: Preview MetaPost output image',
    })
  end
end

return M
