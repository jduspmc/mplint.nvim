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
return {
  {
   'jduspmc/mplint.nvim',
  dependencies = { 'mfussenegger/nvim-lint' },
    -- optional: lazy-load on mp files
    event = { 'BufReadPost', 'BufNewFile' },
    opts = {
      halt_on_error = false, -- true => halt-on-error
      line_diag_key = '<leader>gl', -- set false to disable mapping
      filetypes = { 'mp', 'metapost' },
    },
  },
}
```
License: MIT
