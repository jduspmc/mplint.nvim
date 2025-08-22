local M = {}

function M.setup(opts)
	opts = opts or {}
	local lint = require("lint")
	local parser = require("lint.parser")

	-- gfortran-style parser
	local pattern = "^([^:]+):(%d+):(%d+):%s+([^:]+):%s+(.*)$"
	local groups = { "file", "lnum", "col", "severity", "message" }
	local severity_map = {
		["Error"] = vim.diagnostic.severity.ERROR,
		["Warning"] = vim.diagnostic.severity.WARN,
	}

	-- runner.lua path
	local here = debug.getinfo(1, "S").source:sub(2)
	local runner = here:gsub("init%.lua$", "runner.lua")

	-- Choose mode argument for the runner (we use our own sentinel flag)
	local mode_arg = (opts.halt_on_error and "--mplint-halt") or "--mplint-nonstop"

	-- Use Vim's built-in 'mp' filetype so you keep highlighting
	lint.linters_by_ft.mp = { "mplint" }

	lint.linters.mplint = {
		name = "mplint",
		cmd = "nvim",
		-- We pass our mode flag; nvim-lint will append the filename after these args
		args = { "-l", runner, "--", mode_arg },
		stdin = false,
		append_fname = true,
		stream = "stderr",
		ignore_exitcode = true,
		parser = parser.from_pattern(pattern, groups, severity_map, { source = "mplint" }),
	}
end

return M
