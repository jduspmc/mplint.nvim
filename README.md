# mplint.nvim — MetaPost linter for Neovim

Cross-platform MetaPost linter with three passes:

1. **Compiler errors** (parse `.log`, handles `Runaway loop?` heuristics)
2. **Style checks** (semicolon rules, TeX preamble lines)
3. **Structure checks** (begin/end blocks, delimiters, verbatimtex/btex, simple assignment `=` vs `:=` heuristic)

Diagnostics are emitted as gfortran-style lines:

file:line:col: Severity: message

## Requirements
- Neovim 0.9+ (0.10+ recommended)
- `mpost` in your `$PATH` (TeX Live / MiKTeX)

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
