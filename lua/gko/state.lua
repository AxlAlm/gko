--- The little bit of state the plugin keeps between popups: which session the
--- quick task prompt targets.
local M = { session = nil }

function M.remember(name)
  if name and name ~= "" then
    M.session = name
  end
end

return M
