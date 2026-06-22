-- Previewer for MetaPost output.
-- The module executes the .mp file and renders the output in a floating buffer.
-- If output is EPS, it converts it to PNG first.

local M = {}

local engine = require 'mplint.engine'

M.opts = {
  enabled = false,
  tex_engine = nil,
  scale = 1,
}

local active_jobs = {}
local preview_generation = {}

--- Cancel any active preview job for a specific buffer.
--- @param bufnr integer
function M.cancel(bufnr)
  preview_generation[bufnr] = (preview_generation[bufnr] or 0) + 1
  local old = active_jobs[bufnr]
  if old then
    pcall(function() old:kill(15) end)
    active_jobs[bufnr] = nil
  end
end

--- Options accepted by the MetaPost previewer.
--- @class PreviewOpts
--- @field bufnr? integer Buffer to preview. Defaults to the current buffer.
--- @field scale? number Image scaling factor. Overrides the configured preview_scale for this invocation only.

--- Run the MetaPost previewer.
--- Compiles the MetaPost source into a temporary directory, renders the
--- generated image using image.nvim, and automatically removes the temporary
--- directory when the preview window is closed.
---
--- @param opts? PreviewOpts Preview options.
function M.preview(opts)
  if not M.opts.enabled then return end
  opts = opts or {}
  opts.bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local bufnr = opts.bufnr
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'mp' then
    vim.notify('mplint: current buffer is not a MetaPost buffer', vim.log.levels.ERROR)
    return
  end

  -- 1. Check if image.nvim is installed
  local has_image, image = pcall(require, 'image')
  if not has_image then
    vim.notify('mplint: image.nvim is not installed', vim.log.levels.ERROR)
    return
  end

  -- 2. Check if mpost is available in PATH
  if vim.fn.executable 'mpost' ~= 1 then
    vim.notify('mplint: mpost not found in PATH', vim.log.levels.ERROR)
    return
  end

  -- bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Used to discard stale compile/convert/render jobs.
  preview_generation[bufnr] = (preview_generation[bufnr] or 0) + 1
  local generation = preview_generation[bufnr]

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_name = vim.api.nvim_buf_get_name(bufnr)

  -- 3. Create a unique temporary directory
  local temp_dir = vim.fn.tempname()
  if vim.fn.mkdir(temp_dir, 'p') ~= 1 then
    vim.notify('mplint: failed to create temporary directory', vim.log.levels.ERROR)
    return
  end

  -- Write the buffer contents to input.mp in the temporary directory
  local temp_mp = vim.fs.joinpath(temp_dir, 'input.mp')
  local f = io.open(temp_mp, 'w')
  if not f then
    vim.notify('mplint: failed to create temporary file', vim.log.levels.ERROR)
    pcall(vim.fn.delete, temp_dir, 'rf')
    return
  end
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()

  -- Get workspace environment and determine TeX engine backend
  local env, auto_tex = engine.get_workspace_env(buf_name, lines)
  local tex_opt = M.opts.tex_engine or auto_tex

  -- 4. Construct compiler arguments with no additional flags
  local mpost_args = { 'mpost' }
  if tex_opt then table.insert(mpost_args, '-tex=' .. tex_opt) end
  table.insert(mpost_args, 'input.mp')

  -- Cancel any previous preview compile jobs for the buffer
  local old = active_jobs[bufnr]
  if old then
    active_jobs[bufnr] = nil
    pcall(function() old:kill(15) end)
  end

  -- 5. Execute mpost compiler asynchronously
  -- Track the current compile job. Combined with preview_generation,
  -- this prevents stale compile, conversion and render callbacks.
  local job
  job = vim.system(mpost_args, { cwd = temp_dir, env = env }, function(obj)
    vim.schedule(function()
      if preview_generation[bufnr] ~= generation then
        pcall(vim.fn.delete, temp_dir, 'rf')
        return
      end

      if active_jobs[bufnr] ~= job then
        -- A newer preview has already started.
        pcall(vim.fn.delete, temp_dir, 'rf')
        return
      end
      active_jobs[bufnr] = nil

      -- check if compilation fails
      if obj.code ~= 0 then
        local msg = string.format('mplint: MetaPost failed (exit code %d)', obj.code)

        local output = obj.stderr or ''
        if output == '' then output = obj.stdout or '' end

        if output ~= '' then
          local elines = vim.split(vim.trim(output), '\n')
          local first = math.max(1, #elines - 9)
          output = table.concat(elines, '\n', first, #elines)
          msg = msg .. '\n\n' .. output
        end

        vim.notify(msg, vim.log.levels.ERROR)
        pcall(vim.fn.delete, temp_dir, 'rf')
        return
      end

      -- Check if any image files (SVG, PNG, JPG, JPEG or MetaPost output numbers) were generated
      local files = vim.fn.glob(vim.fs.joinpath(temp_dir, '*'), true, true)
      local candidates = {
        svg = {},
        png = {},
        jpg = {},
        jpeg = {},
      }
      local eps_candidate = {}

      -- Collect generated image candidates
      for _, file_path in ipairs(files) do
        local name = vim.fs.basename(file_path)
        local ext = name:match '%.([^%.]+)$'
        if ext then
          ext = ext:lower()
          if ext == 'svg' or ext == 'png' or ext == 'jpg' or ext == 'jpeg' then
            table.insert(candidates[ext], file_path)
          elseif ext == 'eps' or ext == 'ps' or ext:match '^%d+$' then
            table.insert(eps_candidate, file_path)
          end
        end
      end

      -- Prefer directly usable formats first
      local image_path = candidates.svg[1] or candidates.png[1] or candidates.jpg[1] or candidates.jpeg[1]

      -- Fall back to formats that require conversion
      local needs_conversion = false
      if not image_path and eps_candidate[1] then
        image_path = eps_candidate[1]
        needs_conversion = true
      end

      -- If no image of any known kind was generated, clean up and notify
      if not image_path then
        vim.notify('mplint: compilation succeeded but produced no preview image', vim.log.levels.WARN)
        pcall(vim.fn.delete, temp_dir, 'rf')
        return
      end

      local function render_and_display(final_path)
        if preview_generation[bufnr] ~= generation then
          pcall(vim.fn.delete, temp_dir, 'rf')
          return
        end
        -- Load image to get original pixel dimensions
        local img = image.from_file(final_path, {
          ignore_global_max_size = true,
          max_width_window_percentage = 100,
          max_height_window_percentage = 100,
        })

        if not img or not img.image_width or not img.image_height or img.image_width == 0 or img.image_height == 0 then
          vim.notify('mplint: failed to load generated image', vim.log.levels.ERROR)
          pcall(vim.fn.delete, temp_dir, 'rf')
          return
        end

        -- Try to make it variable size. image.nvim does some tranformation that limits freedom over size
        local scale = opts.scale or M.opts.scale
        local cell_width = require('image.utils.term').get_size().cell_width
        local cell_height = require('image.utils.term').get_size().cell_height

        local iw = img.image_width
        local ih = img.image_height

        -- Calculate floating window layout coordinates preserving aspect ratio
        local width = math.floor(iw / cell_width) * scale
        local height = math.floor(ih / cell_height) * scale

        -- Create scratch buffer for floating preview window
        local buf = vim.api.nvim_create_buf(false, true)

        -- Open the floating window with initial height adjusted for vertical line cell ratios
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          row = math.max(0, math.floor((vim.o.lines - height) / 2)),
          col = math.max(0, math.floor((vim.o.columns - width) / 2)),
          width = width + 2,
          height = height + 2,
          border = 'single',
        })

        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn = 'no'

        img.window = win
        img.buffer = buf

        -- Perform initial render
        img:render {
          width = width,
          height = height,
          x = 1,
          y = 1,
        }

        local function adjust_window()
          if not vim.api.nvim_win_is_valid(win) then return end

          local rg = img.rendered_geometry

          local w = rg and rg.width
          local h = rg and rg.height

          -- wait until fully ready
          if type(w) ~= 'number' or type(h) ~= 'number' then
            vim.defer_fn(adjust_window, 50)
            return
          end

          -- final resize + center
          vim.api.nvim_win_set_config(win, {
            relative = 'editor',
            row = math.max(0, math.floor((vim.o.lines - h) / 2)),
            col = math.max(0, math.floor((vim.o.columns - w) / 2)),
            width = w + 2,
            height = h + 2,
            border = 'single',
          })
        end

        -- start adjustment loop
        adjust_window()

        -- Close window on 'q' keymap, which triggers cleanup autocmd
        vim.keymap.set('n', 'q', function()
          img:clear()
          pcall(vim.api.nvim_win_close, win, true)
        end, { buffer = buf, silent = true })

        -- Autocmd to clear the image render and remove the temporary folder when buffer is wiped out
        vim.api.nvim_create_autocmd('BufWipeout', {
          buffer = buf,
          once = true,
          callback = function()
            img:clear()
            pcall(vim.fn.delete, temp_dir, 'rf')
          end,
        })
      end

      if needs_conversion then
        local converter = nil
        if vim.fn.executable 'magick' == 1 then
          converter = 'magick'
        elseif vim.fn.executable 'convert' == 1 then
          converter = 'convert'
        end

        if not converter then
          vim.notify('mplint: ImageMagick (magick or convert) is required to preview EPS/numbered files', vim.log.levels.ERROR)
          pcall(vim.fn.delete, temp_dir, 'rf')
          return
        end

        local converted_path = image_path .. '.png'
        local convert_args = { converter, image_path, converted_path }

        vim.system(convert_args, {}, function(c_obj)
          vim.schedule(function()
            if preview_generation[bufnr] ~= generation then
              pcall(vim.fn.delete, temp_dir, 'rf')
              return
            end
            if c_obj.code ~= 0 then
              vim.notify('mplint: failed to convert EPS to PNG using ImageMagick', vim.log.levels.ERROR)
              pcall(vim.fn.delete, temp_dir, 'rf')
              return
            end
            render_and_display(converted_path)
          end)
        end)
      else
        render_and_display(image_path)
      end
    end)
  end)
  active_jobs[bufnr] = job
end

return M
