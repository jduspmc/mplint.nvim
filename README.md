# mplint.nvim — MetaPost linter for Neovim

MetaPost linter with three passes:

1. **Compiler errors** (parse `.log`)
2. **Style checks** (semicolon rules, TeX preamble lines)
3. **Structure checks** (begin/end blocks, delimiters, verbatimtex/btex, simple assignment `=` vs `:=` heuristic)

Diagnostics are emitted as gfortran-style lines:

file:line:col: Severity: message

---

## What is MetaPost?

[MetaPost](https://www.tug.org/metapost.html) is a programming language for creating precise, mathematically-defined vector graphics. It descends from METAFONT and outputs PostScript/EPS, making it superb for diagrams, geometric constructions, plots, and figures.

- Official user manual (PDF): **[MetaPost: A User’s Manual](https://www.tug.org/docs/metapost/mpman.pdf)**

### Why linting MetaPost is tricky

MetaPost (and its TeX heritage) has idiosyncrasies that complicate static linting:

- **Error context lives in the `.log`**  
  Messages arrive as `! <message>` followed by `l.<n> <fragment>` and sometimes a continuation line. Not every error includes a caret, and columns aren’t reliable.

- **Semicolons are context-sensitive**  
  Many statements need a `;`, but certain tokens at end-of-line (e.g., `endfor`, `fi`, `etex`) legitimately omit it.

- **TeX preamble lines inside MP sources**  
  Lines beginning with `\` (e.g., `\documentclass{...}`) are TeX, not MP, and **must not** end with `;`.

- **Opaque regions**  
  `verbatimtex … etex` and `btex … etex` block scanning.

- **Balanced construct pairs**  
  Multiple block types span lines and need matching end tokens.

Because of this, **mplint.nvim** parses the `.log` for real compiler errors and augments them with lightweight source heuristics to catch common issues early.

---

## Errors vs Warnings

- **Errors**: findings from the **`.log`** (pass 1) — these are actual `mpost` errors.
- **Warnings**: findings from the **`.mp`** source (passes 2 & 3) — heuristics that flag suspicious lines but aren’t compiler failures.

This separation helps you distinguish “`mpost` actually failed” from “this looks off.”

---

## Requirements

- Neovim (tested on 0.11.3)
- `mpost` available in your `$PATH` (bundled with TeX Live / MiKTeX / MacTeX)
- **nvim-lint**: <https://github.com/mfussenegger/nvim-lint>

---

## Install (lazy.nvim)

```lua
return {
  {
    'jduspmc/mplint.nvim',
    dependencies = { 'mfussenegger/nvim-lint' },
    event = { 'BufReadPost', 'BufNewFile' },
    opts = {
      halt_on_error = false,            -- true => halt-on-error
      line_diag_key = '<leader>gl',     -- set false to disable mapping
      filetypes = { 'mp', 'metapost' },
    },
  },
}
```

# Options & Commands

halt_on_error

false (default): run mpost with --interaction=nonstopmode to surface all .log errors in one go.

true: run with --halt-on-error to stop at the first error.

Keymap (line_diag_key)

Default <leader>gl. Shows all diagnostics on the current line:

# Motivation

I enjoy MetaPost and find it a more direct way to describe geometric drawings than large macro packages like TikZ. My goal with mplint.nvim is to provide a lightweight, helpful linter that makes it easier to learn and iterate with MetaPost—surfacing genuine mpost errors alongside gentle hints for common style/structure issues.

License: MIT
