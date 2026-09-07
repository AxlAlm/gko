--- The read views: the session dashboard, a session's task list, the pending
--- approvals queue, and a single task's result.
local client = require("gko.client")
local config = require("gko.config")
local forms = require("gko.forms")
local state = require("gko.state")
local ui = require("gko.ui")

local M = {}

local MARKERS = { running = "●", waiting_input = "◆", queued = "○" }

local function first_line(s)
  return vim.trim((tostring(s or ""):gsub("%s+", " ")))
end

---------------------------------------------------------------------------
-- task result
---------------------------------------------------------------------------

---@param task table
function M.result(task)
  local float = ui.float({
    title = ("task %s · %s"):format(task.id, task.state),
    footer = "q close",
    width = 0.7,
    height = 0.6,
    cursorline = false,
    filetype = "markdown",
  })

  local lines = { "# prompt", "" }
  vim.list_extend(lines, vim.split(task.prompt or "", "\n"))
  vim.list_extend(lines, { "", "# result", "" })
  if task.result then
    vim.list_extend(lines, vim.split(task.result, "\n"))
  else
    table.insert(lines, ("_" .. task.state .. (task.terminalReason and (" · " .. task.terminalReason) or "") .. "_"))
  end

  vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
  vim.bo[float.buf].modifiable = false
  ui.map(float.buf, "n", { "q", "<Esc>" }, float.close, "gko: close")
  return float
end

---------------------------------------------------------------------------
-- pending approvals
---------------------------------------------------------------------------

function M.requests()
  local float = ui.float({
    title = "pending approvals",
    footer = "y allow   d deny   r refresh   q close",
    width = 0.7,
    height = 0.4,
    wrap = false,
    filetype = "gko-requests",
  })
  vim.bo[float.buf].modifiable = false

  local rows = {}

  local function refresh()
    client.requests(function(list, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      rows = list or {}
      if #rows == 0 then
        ui.render(float.buf, { { { "  nothing is waiting on you", "Comment" } } })
      else
        ui.render(
          float.buf,
          vim.tbl_map(function(r)
            return {
              { "  " },
              { ui.pad(r.tool, 14), "Function" },
              { ui.pad(r.session, 16), "Identifier" },
              { first_line(vim.json.encode(r.input)), "Comment" },
            }
          end, rows)
        )
      end
      ui.set_title(float, ("pending approvals (%d)"):format(#rows))
      ui.clamp_cursor(float)
    end)
  end

  local function answer(allow)
    local r = rows[vim.api.nvim_win_get_cursor(float.win)[1]]
    if not r then
      return
    end
    client.answer(r.id, allow, function(_, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      ui.notify((allow and "allowed " or "denied ") .. r.tool)
      refresh()
    end)
  end

  ui.map(float.buf, "n", "y", function()
    answer(true)
  end, "gko: allow")
  ui.map(float.buf, "n", "d", function()
    answer(false)
  end, "gko: deny")
  ui.map(float.buf, "n", "r", refresh, "gko: refresh")
  ui.map(float.buf, "n", { "q", "<Esc>" }, float.close, "gko: close")

  refresh()
  ui.poll(float, refresh)
  return float
end

---------------------------------------------------------------------------
-- one session's tasks
---------------------------------------------------------------------------

--- Task list. Without a session it lists every task the server knows about.
---@param session string|nil
function M.tasks(session)
  local float = ui.float({
    title = session and ("tasks · " .. session) or "tasks",
    footer = "<CR> result   a new task   x interrupt   q close",
    width = 0.7,
    height = 0.5,
    wrap = false,
    filetype = "gko-tasks",
  })
  vim.bo[float.buf].modifiable = false

  local rows = {}

  local function refresh()
    client.tasks(nil, function(list, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      rows = session and vim.tbl_filter(function(t)
        return t.session == session
      end, list or {}) or (list or {})

      if #rows == 0 then
        ui.render(float.buf, { { { "  no tasks yet — press a to send one", "Comment" } } })
      else
        ui.render(
          float.buf,
          vim.tbl_map(function(t)
            local row = {
              { "  " },
              { ui.pad(MARKERS[t.state] or "·", 2), ui.state_hl(t.state) },
              { ui.pad(t.id, 10), "Comment" },
              { ui.pad(t.state, 16), ui.state_hl(t.state) },
            }
            if not session then
              table.insert(row, { ui.pad(t.session, 16), "Identifier" })
            end
            table.insert(row, { first_line(t.prompt) })
            return row
          end, rows)
        )
      end
      ui.clamp_cursor(float)
    end)
  end

  local function under_cursor()
    return rows[vim.api.nvim_win_get_cursor(float.win)[1]]
  end

  ui.map(float.buf, "n", "<CR>", function()
    local t = under_cursor()
    if t then
      M.result(t)
    end
  end, "gko: show result")
  ui.map(float.buf, "n", "a", function()
    local target = session or (under_cursor() or {}).session
    if target then
      forms.new_task(target, { on_done = refresh })
    end
  end, "gko: new task")
  ui.map(float.buf, "n", "x", function()
    local target = session or (under_cursor() or {}).session
    if not target then
      return
    end
    client.interrupt(target, function(_, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      ui.notify("interrupted " .. target)
      refresh()
    end)
  end, "gko: interrupt")
  ui.map(float.buf, "n", "r", refresh, "gko: refresh")
  ui.map(float.buf, "n", { "q", "<Esc>" }, float.close, "gko: close")

  if session then
    state.remember(session)
  end
  refresh()
  ui.poll(float, refresh)
  return float
end

---------------------------------------------------------------------------
-- the dashboard
---------------------------------------------------------------------------

function M.open()
  local float = ui.float({
    title = "gko",
    footer = "<CR> tasks   a task   n new   m mode   x interrupt   p approvals   q close",
    width = 0.6,
    height = 0.4,
    wrap = false,
    filetype = "gko-sessions",
  })
  vim.bo[float.buf].modifiable = false

  local rows, pending = {}, 0

  local function refresh()
    client.sessions(function(list, err)
      if err then
        ui.render(float.buf, { { { "  " .. err, "DiagnosticError" } } })
        return
      end
      rows = list or {}
      if #rows == 0 then
        ui.render(float.buf, { { { "  no sessions — press n to create one", "Comment" } } })
      else
        ui.render(
          float.buf,
          vim.tbl_map(function(s)
            local busy = s.current and "running" or "idle"
            return {
              { "  " },
              { ui.pad(s.current and MARKERS.running or MARKERS.queued, 2), ui.state_hl(s.current and "running" or "queued") },
              { ui.pad(s.name, 20), "Identifier" },
              { ui.pad(s.mode, 18), "Type" },
              { ui.pad(busy, 9), s.current and "DiagnosticInfo" or "Comment" },
              { s.queued > 0 and (s.queued .. " queued") or "", "Comment" },
            }
          end, rows)
        )
      end
      ui.clamp_cursor(float)
    end)

    client.health(function(h)
      pending = h and h.pendingApprovals or 0
      ui.set_title(float, pending > 0 and ("gko · %d waiting on you"):format(pending) or "gko")
    end)
  end

  local function under_cursor()
    if not vim.api.nvim_win_is_valid(float.win) then
      return nil
    end
    return rows[vim.api.nvim_win_get_cursor(float.win)[1]]
  end

  ui.map(float.buf, "n", "<CR>", function()
    local s = under_cursor()
    if s then
      float.close()
      M.tasks(s.name)
    end
  end, "gko: open session")
  ui.map(float.buf, "n", "a", function()
    local s = under_cursor()
    if s then
      forms.new_task(s.name, { on_done = refresh })
    end
  end, "gko: new task")
  ui.map(float.buf, "n", "n", function()
    forms.new_session({ on_done = refresh })
  end, "gko: new session")
  ui.map(float.buf, "n", "m", function()
    local s = under_cursor()
    if not s then
      return
    end
    vim.ui.select(config.modes, { prompt = "mode for " .. s.name }, function(mode)
      if not mode then
        return
      end
      client.set_mode(s.name, mode, function(res, err)
        if err then
          return ui.notify(err, vim.log.levels.ERROR)
        end
        if res.pendingApprovals > 0 then
          ui.notify(("%s is %s, but %d approval(s) raised before the switch still need an answer")
            :format(s.name, mode, res.pendingApprovals), vim.log.levels.WARN)
        else
          ui.notify(s.name .. " is now " .. mode)
        end
        refresh()
      end)
    end)
  end, "gko: set mode")
  ui.map(float.buf, "n", "x", function()
    local s = under_cursor()
    if not s then
      return
    end
    client.interrupt(s.name, function(_, err)
      if err then
        return ui.notify(err, vim.log.levels.ERROR)
      end
      ui.notify("interrupted " .. s.name)
      refresh()
    end)
  end, "gko: interrupt")
  ui.map(float.buf, "n", "p", function()
    M.requests()
  end, "gko: approvals")
  ui.map(float.buf, "n", "r", refresh, "gko: refresh")
  ui.map(float.buf, "n", { "q", "<Esc>" }, float.close, "gko: close")

  refresh()
  ui.poll(float, refresh)
  return float
end

return M
