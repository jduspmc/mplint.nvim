local M = {}

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", {
		halt_on_error = false, -- nonstop by default
		line_diag_key = "<leader>gl", -- set false to disable
		filetypes = { "mp", "metapost" }, -- which fts get mplint
		events = { "BufWritePost", "InsertLeave" }, -- when to lint
		-- Formatter opts
		indent_width = 4,
		indent_blank_lines = true, -- add blank lines before/after block
		indent_key = "<leader>fm", -- set false to disable keymap
	}, opts or {})

	---------------------------------------------------------------------------
	-- Linter
	---------------------------------------------------------------------------

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

	-- mode flag for the runner
	local mode_arg = (opts.halt_on_error and "--mplint-halt") or "--mplint-nonstop"

	lint.linters.mplint = {
		name = "mplint",
		cmd = "nvim",
		args = { "-l", runner, "--", mode_arg }, -- nvim -l runner.lua -- <flag> <file>
		stdin = false,
		append_fname = true,
		stream = "stderr",
		ignore_exitcode = true,
		parser = parser.from_pattern(pattern, groups, severity_map, { source = "mplint" }),
	}

	-- attach to requested filetypes without clobbering others
	lint.linters_by_ft = lint.linters_by_ft or {}
	for _, ft in ipairs(opts.filetypes) do
		local list = lint.linters_by_ft[ft] or {}
		if not vim.tbl_contains(list, "mplint") then
			table.insert(list, "mplint")
		end
		lint.linters_by_ft[ft] = list
	end

	-- autolint only for our filetypes
	local ft_set = {}
	for _, ft in ipairs(opts.filetypes) do
		ft_set[ft] = true
	end

	local grp = vim.api.nvim_create_augroup("mplint.nvim/autolint", { clear = true })
	vim.api.nvim_create_autocmd(opts.events, {
		group = grp,
		callback = function(ev)
			local ft = vim.bo[ev.buf].filetype
			if ft_set[ft] and vim.bo[ev.buf].modifiable then
				require("lint").try_lint("mplint")
			end
		end,
	})

	-- toggle halt <-> nonstop
	vim.api.nvim_create_user_command("MplintToggleHalt", function()
		local l = require("lint").linters.mplint
		if not l then
			return
		end
		local was_halt = vim.tbl_contains(l.args, "--mplint-halt")
		for i, a in ipairs(l.args) do
			if a == "--mplint-halt" then
				l.args[i] = "--mplint-nonstop"
			end
			if a == "--mplint-nonstop" then
				l.args[i] = "--mplint-halt"
			end
		end
		vim.notify("mplint mode: " .. (was_halt and "nonstopmode" or "halt-on-error"))
		require("lint").try_lint("mplint") -- re-run immediately
	end, {})

	-- buffer-local keymap (optional)
	if opts.line_diag_key ~= false then
		local key = opts.line_diag_key or "<leader>gl"
		local kgrp = vim.api.nvim_create_augroup("mplint.nvim/keymap", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			group = kgrp,
			pattern = opts.filetypes,
			callback = function(ev)
				vim.keymap.set("n", key, function()
					vim.diagnostic.open_float({ scope = "line", focus = false })
				end, { buffer = ev.buf, desc = "mplint: line diagnostics" })
			end,
		})
	end

	---------------------------------------------------------------------------
	-- Formatter
	---------------------------------------------------------------------------
	local function indent_current_buffer()
		local fmt = require("mplint.formatter")
		-- pass through your options; adapt names if your formatter expects different keys
		fmt.format_buffer({
			indent_width = opts.indent_width,
			blank_lines = opts.indent_blank_lines,
		})
		require("lint").try_lint("mplint")
	end

	vim.api.nvim_create_user_command("MplintIndent", function()
		indent_current_buffer()
	end, { desc = "mplint: reindent MetaPost buffer" })

	if opts.indent_key then
		local ig = vim.api.nvim_create_augroup("mplint.nvim/indent_key", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			group = ig,
			pattern = opts.filetypes,
			callback = function(ev)
				vim.keymap.set(
					"n",
					opts.indent_key,
					indent_current_buffer,
					{ buffer = ev.buf, desc = "mplint: indent buffer" }
				)
			end,
		})
	end
end

return M
