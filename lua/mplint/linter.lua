local M = {}

local runner = require 'mplint.runner'
local engine = require 'mplint.engine'
local ui = require 'mplint.ui'

M.opts = {
  halt_on_error = false,
  enabled = true,
  tex_engine = nil,
}

local ns = vim.api.nvim_create_namespace 'mplint'
local active_jobs = {}
local generations = {}

--- Cancel any active linter job for a specific buffer.
--- @param bufnr integer
function M.cancel(bufnr)
  if active_jobs[bufnr] then
    pcall(function() active_jobs[bufnr]:kill(15) end)
    active_jobs[bufnr] = nil
  end
end

local function read_lines(path)
  local t = {}
  local f = io.open(path, 'r')
  if not f then return nil end
  for line in f:lines() do
    t[#t + 1] = line:gsub('\r$', '')
  end
  f:close()
  return t
end

--- Run the MetaPost linter on a specific buffer.
--- If mpost is missing from the system PATH, a buffer-level diagnostic error is registered.
--- @param bufnr integer|nil The buffer number to lint (defaults to current buffer if omitted)
function M.lint(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  generations[bufnr] = (generations[bufnr] or 0) + 1
  local current_generation = generations[bufnr]

  if not M.opts.enabled then return ui.clear(bufnr) end

  if vim.fn.executable 'mpost' ~= 1 then
    vim.diagnostic.set(ns, bufnr, {
      {
        bufnr = bufnr,
        lnum = 0,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = 'mpost not found in PATH',
        source = 'mplint',
      },
    })
    return
  end

  if active_jobs[bufnr] then
    pcall(function() active_jobs[bufnr]:kill(15) end)
    active_jobs[bufnr] = nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local temp_mp = vim.fn.tempname() .. '.mp'
  local f = io.open(temp_mp, 'w')
  if not f then
    vim.notify('mplint: failed to create temporary file', vim.log.levels.ERROR)
    return
  end
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local env, auto_tex = engine.get_workspace_env(buf_name, lines)
  local flag = M.opts.halt_on_error and '-halt-on-error' or '-interaction=nonstopmode'
  local tex_opt = M.opts.tex_engine or auto_tex

  local mpost_args = { 'mpost', flag }
  if tex_opt then table.insert(mpost_args, '-tex=' .. tex_opt) end
  table.insert(mpost_args, temp_mp:match '[^/\\]+$' or temp_mp)

  local temp_dir = temp_mp:match '(.+)/[^/]+$' or vim.fs.dirname(temp_mp)

  active_jobs[bufnr] = vim.system(mpost_args, { cwd = temp_dir, env = env }, function(obj)
    vim.schedule(function()
      local stale = generations[bufnr] ~= current_generation

      active_jobs[bufnr] = nil
      local temp_log = temp_mp:gsub('%.mp$', '.log')
      local log_lines = read_lines(temp_log)

      -- Clean workspace safely
      local base_temp = temp_mp:gsub('%.mp$', '')
      for _, file_path in ipairs(vim.fn.glob(base_temp .. '.*', true, true)) do
        vim.fn.delete(file_path)
      end
      if stale then return end

      -- Run local heuristics regardless of compiler output
      local issues = runner.run_heuristics(lines)

      if log_lines then
        -- Log exists: parse normal compiler errors
        local compiler_errors = runner.parse_log(log_lines, lines)
        vim.list_extend(issues, compiler_errors)
      else
        -- ADDED: Log does not exist, report compilation failure
        local fallback_msg = 'mpost failed to generate a log file.'
        if obj.code and obj.code ~= 0 then fallback_msg = string.format('mpost crashed (exit code %d). No log file generated.', obj.code) end

        table.insert(issues, {
          bufnr = bufnr,
          lnum = 0,
          col = 0,
          severity = vim.diagnostic.severity.ERROR,
          message = fallback_msg,
          source = 'mplint',
        })
      end

      if vim.api.nvim_buf_is_valid(bufnr) then ui.publish_diagnostics(bufnr, issues, #lines) end
    end)
  end)
end

return M
