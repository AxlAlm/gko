if vim.g.loaded_gko then
  return
end
vim.g.loaded_gko = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("[gko] requires neovim 0.10+", vim.log.levels.ERROR)
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, function(a)
    require("gko")[fn](a.args ~= "" and a.args or nil)
  end, opts or { desc = "gko: " .. fn })
end

--- Completes on live session names, so it only costs a request when you
--- actually press <Tab>.
local function complete_session(lead)
  return vim.tbl_filter(function(name)
    return name:find(lead, 1, true) == 1
  end, require("gko.client").session_names())
end

cmd("Gko", "toggle", { desc = "gko: session dashboard" })
cmd("GkoSessions", "sessions", { desc = "gko: list sessions" })
cmd("GkoRequests", "requests", { desc = "gko: pending approvals" })
cmd("GkoHealth", "health", { desc = "gko: server health" })
cmd("GkoSession", "session", { desc = "gko: new session" })

cmd("GkoTasks", "tasks", {
  desc = "gko: list tasks, optionally for one session",
  nargs = "?",
  complete = complete_session,
})
cmd("GkoTask", "task", {
  desc = "gko: send a task",
  nargs = "?",
  complete = complete_session,
})
