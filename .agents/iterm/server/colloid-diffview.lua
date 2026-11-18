-- Keys for diffview, which the iTerm2 Diff pane opens through pane-diff; the
-- same two keys the Mac's nvim config binds (setup-server.sh installs this file
-- only where the server has no ~/.config/nvim of its own).
vim.keymap.set("n", "<leader>gv", "<cmd>DiffviewOpen<cr>", { desc = "Diff view (uncommitted)" })
vim.keymap.set("n", "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", { desc = "File history" })
