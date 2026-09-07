--- Thin async HTTP client over curl. The server is loopback-only and rejects
--- anything carrying an Origin header, which curl never sends.
local config = require("gko.config")

local M = {}

---@param method string
---@param path string
---@param body table|nil
---@param cb fun(data: any|nil, err: string|nil)
local function request(method, path, body, cb)
  local args = {
    "curl",
    "-sS",
    "--max-time",
    tostring(config.options.timeout),
    "-X",
    method,
    config.options.url .. path,
  }
  if body then
    vim.list_extend(args, { "-H", "content-type: application/json", "-d", vim.json.encode(body) })
  end

  vim.system(args, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      local err = vim.trim(res.stderr or "")
      if err == "" then
        err = "curl exited " .. res.code
      end
      if res.code == 7 then
        err = "agentd is not reachable at " .. config.options.url
      end
      return cb(nil, err)
    end

    local ok, decoded = pcall(vim.json.decode, res.stdout, { luanil = { object = true } })
    if not ok then
      return cb(nil, "unreadable response: " .. vim.trim(res.stdout or ""))
    end
    if type(decoded) == "table" and decoded.error then
      return cb(nil, decoded.error)
    end
    cb(decoded, nil)
  end))
end

function M.health(cb)
  request("GET", "/health", nil, cb)
end

function M.sessions(cb)
  request("GET", "/sessions", nil, cb)
end

function M.create_session(name, cwd, mode, cb)
  request("POST", "/sessions", { name = name, cwd = cwd, mode = mode }, cb)
end

function M.set_mode(session, mode, cb)
  request("POST", "/sessions/" .. vim.uri_encode(session) .. "/mode", { mode = mode }, cb)
end

function M.interrupt(session, cb)
  request("POST", "/sessions/" .. vim.uri_encode(session) .. "/interrupt", {}, cb)
end

function M.send_task(session, text, mode, cb)
  request("POST", "/sessions/" .. vim.uri_encode(session) .. "/tasks", { text = text, mode = mode }, cb)
end

---@param state string|nil filter on task state
function M.tasks(state, cb)
  request("GET", "/tasks" .. (state and ("?state=" .. vim.uri_encode(state)) or ""), nil, cb)
end

--- Blocking session fetch, for command-line completion only — a short timeout
--- because this runs while the user is mid-keystroke.
---@return string[] names
function M.session_names()
  local res = vim
    .system({ "curl", "-sS", "--max-time", "1", config.options.url .. "/sessions" }, { text = true })
    :wait(1500)
  if res.code ~= 0 then
    return {}
  end
  local ok, list = pcall(vim.json.decode, res.stdout)
  if not ok or type(list) ~= "table" then
    return {}
  end
  return vim.tbl_map(function(s)
    return s.name
  end, list)
end

function M.requests(cb)
  request("GET", "/requests", nil, cb)
end

function M.answer(id, allow, cb)
  request("POST", "/requests/" .. vim.uri_encode(id) .. "/answer", { allow = allow }, cb)
end

return M
