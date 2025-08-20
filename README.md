# mplint.nvim — MetaPost linter for Neovim

Cross-platform MetaPost linter with three passes:

1. **Compiler errors** (parse `.log`)
2. **Style checks** (semicolon rules, TeX preamble lines)
3. **Structure checks** (begin/end blocks, delimiters, verbatimtex/btex, simple assignment `=` vs `:=` heuristic)

Diagnostics are emitted as gfortran-style lines:

file:line:col: Severity: message

## Requirements
- Neovim (0.11.3 tested)
- `mpost` in your `$PATH`. It comes with main LaTeX distros (TeX Live / MiKTeX / MacTeX).

## Install (lazy.nvim)
```lua
{
  'jduspmc/mplint.nvim',
  dependencies = { 'mfussenegger/nvim-lint' },
  config = function()
    require('mplint').setup()
    -- optional: auto-lint on write/leave insert
    local lint = require('lint')
    vim.api.nvim_create_autocmd({ 'BufWritePost', 'InsertLeave' }, {
      callback = function()
        if vim.bo.filetype == 'metapost' and vim.bo.modifiable then
          lint.try_lint('mplint')
        end
      end,
    })
  end,
}
