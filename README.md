# mplint.nvim — MetaPost linter for Neovim

MetaPost linter with three passes:

1. **Compiler errors** (parse **`.log`**)
2. **Style checks** (semicolon rules, TeX preamble lines)
3. **Structure checks** (begin/end blocks, delimiters, verbatimtex/btex, simple assignment `=` vs `:=` heuristic)

Diagnostics are emitted as gfortran-style lines:

file:line:col: Severity: message

---

## What is MetaPost?

[MetaPost](https://www.tug.org/metapost.html) is a programming language for creating vector graphics, designed by Donald Knuth and derived from METAFONT’s ideas but producing PostScript/Encapsulated PostScript output. It’s particularly good at precise, mathematically-defined drawings (diagrams, plots, geometric constructions).

- Official user manual (PDF): **[MetaPost: A User’s Manual](https://www.tug.org/docs/metapost/mpman.pdf)**

### Why linting MetaPost is tricky

MetaPost (and its TeX heritage) has idiosyncrasies that complicate static linting:

- **Error context lives in the `.log`**  
  Messages arrive as `! <message>` followed by `l.<n> <fragment>` and sometimes a continuation line. Not every error includes a `<n>` or a stable column.

- **Semicolons are context-sensitive**  
  Many statements need a `;`, but certain tokens at end-of-line (e.g., `endfor`, `fi`, `etex`) legitimately omit it.

- **TeX preamble blending**  
  Lines beginning with `\` (e.g., `\documentclass{...}`) are TeX, not MetaPost, and **must not** end with `;`.

- **Opaque regions**  
  `verbatimtex … etex` and `btex … etex` are treated as black boxes.

- **Balanced construct pairs**  
  Multiple block types span lines and need matching end tokens.

- **Construct pairs**
  `beginfig…endfig`, `begingroup…endgroup`, `def/vardef…enddef`, `if…fi`, `for/forsuffixes…endfor`—all of which can be unbalanced across lines.

Because of this, `mplint.nvim` takes a pragmatic approach: it parses the `.log` for true compiler errors, and augments that with lightweight source heuristics (style and structure) to help you catch common mistakes early.

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

MetaPost often **cascades** errors: a single mistake (e.g., a missing `;` or an unclosed `enddef`) can derail parsing and produce **many** `! …` messages in the `.log`. In those cases, it’s usually more productive to fix the **first** real error and re-run.

- `halt_on_error = true` → runs `mpost` with `--halt-on-error` and **stops at the first error**.  
  Use this when the **`.log`** explodes with follow-on errors caused by one typo.

- `halt_on_error = false` (default) → runs with `--interaction=nonstopmode` and **shows all errors** in one pass.  
  Use this when you want the full picture or to scan for multiple independent issues.

You can toggle this option at runtime:
- `:MplintToggleHalt` → It flips the internal runner flag and immediately re-lints the current buffer.

- Keymap (`line_diag_key`)
  Default `<leader>gl`. Shows all diagnostics on the current line when runnig with `halt_on_error = false`.

- Filetypes (`filetypes`)
  Defaults to { 'mp', 'metapost' }.

# Motivation

I enjoy MetaPost and find it a more direct way to describe geometric drawings than large macro packages like TikZ. My goal with mplint.nvim is to provide a lightweight, helpful linter that makes it easier to learn and iterate with MetaPost, surfacing genuine mpost errors alongside gentle hints for common style/structure issues.

License: MIT
