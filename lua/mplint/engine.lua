-- This module prepares and executes the MetaPost compiler.
-- Figures out the environment needed to run MetaPost.
-- Runs MetaPost synchronously and returns the log.

local M = {}

--- Analyze the buffer context to generate the system environment map and detect TeX engine dependencies.
--- This updates the `MPINPUTS` environment variable to look in the active project directory first.
--- @param buf_path string|nil The absolute file path of the current buffer (falls back to current working directory if missing).
--- @param lines string[]|nil The line contents of the buffer, parsed to scan for LaTeX engine footprints.
--- @return table<string, string> env The modified environment variable mapping to feed into the compiler subsystem.
--- @return string|nil tex_engine The detected TeX engine variant name (e.g., 'latex'), or `nil` if it looks like standard MetaPost
--- @return string project_dir The calculated project base directory path.
function M.get_workspace_env(buf_path, lines)
  local project_dir = (buf_path and buf_path ~= '') and vim.fs.dirname(buf_path) or vim.fn.getcwd()

  local tex_engine = nil
  if lines then
    for _, line in ipairs(lines) do
      if line:match '\\documentclass' or line:match '\\begin{document}' or line:match '\\usepackage' then
        tex_engine = 'latex'
        break
      end
    end
  end

  -- SWAPPED: project_dir is now the 3rd return value
  local sep = package.config:sub(1, 1) == '\\' and ';' or ':'
  return vim.tbl_extend('force', vim.fn.environ(), {
    MPINPUTS = project_dir .. sep .. (os.getenv 'MPINPUTS' or ''),
  }), tex_engine
end

--- Execute the MetaPost compiler synchronously on a standalone virtual file footprint.
--- Creates a isolated temp file wrapper, fires the compiler process, harvests generated log messages, and scrubs structural artifacts from disk.
--- @param lines string[] The raw buffer contents to stream directly into the compiler.
--- @param env table<string, string> The system environment variable context map to execute the compiler run inside.
--- @param flag string|nil Optional execution runtime flag overrides (defaults to '-interaction=nonstopmode' if omitted).
--- @param tex_engine string|nil Explicit external TeX processor engine argument flag mapping (e.g., 'latex').
--- @return string[] log_lines Sequential lines read back directly out of the generated runtime compilation `.log` file footprint.
function M.run_compiler_sync(lines, env, flag, tex_engine)
  local temp_mp = vim.fn.tempname() .. '.mp'
  local f = io.open(temp_mp, 'w')
  if not f then
    vim.notify('mplint: failed to create temporary file', vim.log.levels.ERROR)
    return {}
  end
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()

  local temp_dir = temp_mp:match '(.+)/[^/]+$' or vim.fs.dirname(temp_mp)
  local file_name = temp_mp:match '[^/\\]+$'

  local mpost_args = { 'mpost', flag or '-interaction=nonstopmode' }
  if tex_engine then table.insert(mpost_args, '-tex=' .. tex_engine) end
  table.insert(mpost_args, file_name)

  vim.system(mpost_args, { cwd = temp_dir, env = env }):wait()

  local log_lines = {}
  local log_f = io.open(temp_mp:gsub('%.mp$', '.log'), 'r')
  if log_f then
    for line in log_f:lines() do
      log_lines[#log_lines + 1] = line
    end
    log_f:close()
  end

  local base_temp = temp_mp:gsub('%.mp$', '')
  for _, path in ipairs(vim.fn.glob(base_temp .. '.*', true, true)) do
    vim.fn.delete(path)
  end

  return log_lines
end

return M
