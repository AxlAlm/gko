--- gko.nvim — a lite popup UI over the agentd server (server/server.ts).
local client = require("gko.client")
local config = require("gko.config")
local forms = require("gko.forms")
local menu = require("gko.menu")
local state = require("gko.state")
local ui = require("gko.ui")

local M = {}

M.setup = config.setup

local dashboard = nil

--- The session dashboard, or close it if it is already up.
function M.toggle()
  if dashboard and not dashboard.closed and vim.api.nvim_win_is_valid(dashboard.win) then
    dashboard.close()
    dashboard = nil
    return
  end
  dashboard = menu.open()
end

M.sessions = M.toggle

--- Task list — one session's, or every session's.
---@param session string|nil
function M.tasks(session)
  menu.tasks(session)
end

--- A task prompt buffer: the named session, the last one you touched, or a picker.
---@param session string|nil
function M.task(session)
  if session and session ~= "" then
    return forms.new_task(session)
  end
  if not state.session then
    return forms.pick_session(forms.new_task)
  end
  client.sessions(function(sessions, err)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    for _, s in ipairs(sessions or {}) do
      if s.name == state.session then
        return forms.new_task(s.name)
      end
    end
    state.session = nil -- it went away with the server
    forms.pick_session(forms.new_task)
  end)
end

function M.session()
  forms.new_session()
end

function M.requests()
  menu.requests()
end

function M.health()
  client.health(function(h, err)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    ui.notify(("up %ds · %d sessions · %d tasks · %d pending approvals")
      :format(h.uptimeSeconds, h.sessions, h.tasks, h.pendingApprovals))
  end)
end

return M
