--- Spec lazy.nvim reads out of this repo when someone requires it as a plugin.
--- A user's own spec (`{ "you/gko" }`) is merged on top of this, so the lazy
--- loading triggers and default keymaps come for free.
return {
  cmd = { "Gko", "GkoTask", "GkoTasks", "GkoSession", "GkoSessions", "GkoRequests", "GkoHealth" },
  keys = {
    { "<leader>gk", function() require("gko").toggle() end, desc = "gko: sessions" },
    { "<leader>ga", function() require("gko").task() end, desc = "gko: new task" },
    { "<leader>gn", function() require("gko").session() end, desc = "gko: new session" },
    { "<leader>gp", function() require("gko").requests() end, desc = "gko: approvals" },
  },
  opts = {},
}
