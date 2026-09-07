--- Float plumbing shared by every gko view: geometry, keymaps, segment
--- rendering. Nothing here knows about the server.
local config = require("gko.config")

local M = {}
M.ns = vim.api.nvim_create_namespace("gko")

function M.notify(msg, level)
  vim.notify("[gko] " .. msg, level or vim.log.levels.INFO)
end

---@class GkoFloat
---@field buf integer
---@field win integer
---@field close fun()

--- Centered float. `width`/`height` are absolute when >= 1 and a fraction of
--- the editor when < 1.
---@return GkoFloat
function M.float(opts)
  local ui = vim.api.nvim_list_uis()[1]
  local total_w = ui and ui.width or vim.o.columns
  local total_h = ui and ui.height or vim.o.lines

  local function dim(v, total, max)
    local n = v < 1 and math.floor(total * v) or v
    return math.max(10, math.min(n, max or total - 4))
  end

  local width = dim(opts.width or 0.6, total_w)
  local height = dim(opts.height or 0.5, total_h)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "gko"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((total_h - height) / 2) - 1,
    col = math.floor((total_w - width) / 2),
    style = "minimal",
    border = config.options.border,
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
    footer = opts.footer and (" " .. opts.footer .. " ") or nil,
    footer_pos = opts.footer and "center" or nil,
  })
  vim.wo[win].wrap = opts.wrap ~= false
  vim.wo[win].cursorline = opts.cursorline ~= false
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder,FloatTitle:FloatTitle"

  local float
  float = {
    buf = buf,
    win = win,
    close = function()
      if float.closed then
        return
      end
      float.closed = true
      if opts.on_close then
        pcall(opts.on_close)
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  }

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      float.close()
    end,
  })

  return float
end

function M.set_title(float, title, footer)
  if not vim.api.nvim_win_is_valid(float.win) then
    return
  end
  local cfg = { title = " " .. title .. " ", title_pos = "center" }
  if footer then
    cfg.footer = " " .. footer .. " "
    cfg.footer_pos = "center"
  end
  vim.api.nvim_win_set_config(float.win, cfg)
end

---@param buf integer
---@param lhs string|string[]
function M.map(buf, mode, lhs, fn, desc)
  for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

--- Render rows of highlighted segments. A row is a list of `{ text, hl }`
--- pairs; `hl` may be nil for unhighlighted text.
---@param buf integer
---@param rows table[]
function M.render(buf, rows)
  local lines, marks = {}, {}
  for i, row in ipairs(rows) do
    local col, text = 0, ""
    for _, seg in ipairs(row) do
      local chunk = seg[1] or ""
      if seg[2] then
        table.insert(marks, { i - 1, col, col + #chunk, seg[2] })
      end
      text = text .. chunk
      col = col + #chunk
    end
    lines[i] = text
  end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

--- Keep the cursor on a valid line after a re-render.
function M.clamp_cursor(float, min_row)
  if not vim.api.nvim_win_is_valid(float.win) then
    return
  end
  local last = vim.api.nvim_buf_line_count(float.buf)
  local row = vim.api.nvim_win_get_cursor(float.win)[1]
  row = math.max(min_row or 1, math.min(row, last))
  pcall(vim.api.nvim_win_set_cursor, float.win, { row, 0 })
end

--- Poll `fn` every `config.refresh` ms until the float closes.
function M.poll(float, fn)
  if config.options.refresh <= 0 then
    return
  end
  local timer = vim.uv.new_timer()
  timer:start(
    config.options.refresh,
    config.options.refresh,
    vim.schedule_wrap(function()
      if float.closed or not vim.api.nvim_win_is_valid(float.win) then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
        return
      end
      fn()
    end)
  )
end

function M.pad(s, n)
  s = tostring(s or "")
  if vim.fn.strdisplaywidth(s) > n then
    return vim.fn.strcharpart(s, 0, n - 1) .. "…"
  end
  return s .. string.rep(" ", n - vim.fn.strdisplaywidth(s))
end

--- Highlight group for a task state.
function M.state_hl(state)
  if state == "running" then
    return "DiagnosticInfo"
  elseif state == "waiting_input" then
    return "DiagnosticWarn"
  elseif state == "queued" then
    return "Comment"
  elseif state == "success" then
    return "DiagnosticOk"
  end
  return "DiagnosticError"
end

return M
