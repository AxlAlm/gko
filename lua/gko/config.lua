local M = {}

---@class GkoConfig
---@field url string base URL of agentd
---@field timeout number curl timeout, seconds
---@field refresh number auto-refresh interval for open views, ms (0 disables)
---@field default_mode string permission mode pre-filled in the session form
---@field default_cwd fun():string cwd pre-filled in the session form
---@field border string|table float border
M.defaults = {
  url = "http://127.0.0.1:4747",
  timeout = 10,
  refresh = 1000,
  default_mode = "default",
  default_cwd = function()
    return vim.fn.getcwd()
  end,
  border = "rounded",
}

M.options = vim.deepcopy(M.defaults)

--- Every mode the server accepts, in the order the form cycles them.
M.modes = { "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto" }

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
