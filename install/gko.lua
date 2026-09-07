-- Drop this in ~/.config/nvim/lua/plugins/gko.lua
-- `dir` points at your local checkout, so edits to the plugin are live on the
-- next :Lazy reload — swap it for `"axelalmquist/gko"` once it's pushed.
return {
	dir = "~/repos/gko",
	name = "gko",
	cmd = { "Gko", "GkoTask", "GkoTasks", "GkoSession", "GkoSessions", "GkoRequests", "GkoHealth" },
	opts = {
		url = "http://127.0.0.1:4747",
		-- refresh = 1000,       -- ms between auto-refreshes of an open view, 0 = off
		-- default_mode = "default",
		-- border = "rounded",
	},
	keys = {
		{
			"<leader>gk",
			function()
				require("gko").toggle()
			end,
			desc = "gko: sessions",
		},
		{
			"<leader>ga",
			function()
				require("gko").task()
			end,
			desc = "gko: new task",
		},
		{
			"<leader>gt",
			function()
				require("gko").tasks()
			end,
			desc = "gko: tasks",
		},
		{
			"<leader>gn",
			function()
				require("gko").session()
			end,
			desc = "gko: new session",
		},
		{
			"<leader>gp",
			function()
				require("gko").requests()
			end,
			desc = "gko: pending approvals",
		},
	},
}
