--- The two write popups. Both are ordinary `acwrite` buffers in a float: edit
--- with every motion you know, paste, undo — and `:w` is the POST.
local client = require("gko.client")
local config = require("gko.config")
local state = require("gko.state")
local ui = require("gko.ui")

local M = {}

--- Route `:w` on this buffer to `fn` instead of the filesystem. `fn` clears
--- 'modified' itself when the write is accepted, so a rejected write leaves
--- the buffer dirty and `:wq` aborts on E37 rather than silently closing.
local function on_write(buf, name, fn)
  vim.bo[buf].buftype = "acwrite"
  -- Buffer names are unique: an earlier popup for the same session still
  -- holding this name would make set_name fail, so retire it first.
  local stale = vim.fn.bufnr("^" .. name .. "$")
  if stale ~= -1 and stale ~= buf then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].modified = false
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = fn })
end

--- Create-session form: three `key value` lines, validated on write.
---@param opts { on_done?: fun(name: string) }|nil
function M.new_session(opts)
  opts = opts or {}
  local cwd = config.options.default_cwd()
  local lines = {
    "name " .. vim.fn.fnamemodify(cwd, ":t"),
    "cwd  " .. cwd,
    "mode " .. config.options.default_mode,
  }

  local float = ui.float({
    title = "new session",
    footer = ":w create   :q! cancel",
    width = 0.5,
    height = #lines,
    wrap = false,
    cursorline = false,
  })
  vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)

  on_write(float.buf, "gko://session/new", function()
    local fields = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(float.buf, 0, -1, false)) do
      local key, value = line:match("^%s*(%S+)%s+(.*)$")
      if key then
        fields[key] = vim.trim(value)
      end
    end

    if not fields.name or fields.name == "" then
      return ui.notify("a session needs a name", vim.log.levels.WARN)
    end
    if not vim.tbl_contains(config.modes, fields.mode) then
      return ui.notify("mode must be one of " .. table.concat(config.modes, ", "), vim.log.levels.WARN)
    end

    vim.bo[float.buf].modified = false
    client.create_session(fields.name, fields.cwd, fields.mode, function(_, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      state.remember(fields.name)
      ui.notify("session " .. fields.name .. " is up")
      float.close()
      if opts.on_done then
        opts.on_done(fields.name)
      end
    end)
  end)

  vim.api.nvim_win_set_cursor(float.win, { 1, 0 })
  vim.cmd("startinsert!")
  return float
end

--- Task prompt. `:w` sends and empties the buffer for the next one; `:wq`
--- sends and closes.
---@param session string
---@param opts { on_done?: fun(task: table) }|nil
function M.new_task(session, opts)
  opts = opts or {}
  local float = ui.float({
    title = "task → " .. session,
    footer = ":w send   :q! cancel",
    width = 0.6,
    height = 8,
    cursorline = false,
    filetype = "markdown",
  })
  vim.wo[float.win].linebreak = true

  on_write(float.buf, "gko://task/" .. session, function()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(float.buf, 0, -1, false), "\n"))
    if text == "" then
      return ui.notify("nothing to send", vim.log.levels.WARN)
    end

    vim.bo[float.buf].modified = false
    client.send_task(session, text, nil, function(task, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      state.remember(session)
      ui.notify(("task %s queued on %s (%s)"):format(task.id, session, task.mode))
      -- `:wq` already wiped the buffer; after a plain `:w` leave it empty and
      -- ready for the next task.
      if vim.api.nvim_buf_is_valid(float.buf) then
        vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, {})
        vim.bo[float.buf].modified = false
      end
      if opts.on_done then
        opts.on_done(task)
      end
    end)
  end)

  vim.cmd("startinsert")
  return float
end

--- Pick a session, then run `fn(name)`. Skips the picker when there is only one.
function M.pick_session(fn)
  client.sessions(function(sessions, err)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    if #sessions == 0 then
      ui.notify("no sessions yet — creating one", vim.log.levels.WARN)
      return M.new_session({ on_done = fn })
    end
    if #sessions == 1 then
      return fn(sessions[1].name)
    end
    vim.ui.select(sessions, {
      prompt = "gko session",
      format_item = function(s)
        return ("%s  (%s, %d queued)"):format(s.name, s.mode, s.queued)
      end,
    }, function(choice)
      if choice then
        fn(choice.name)
      end
    end)
  end)
end

return M
