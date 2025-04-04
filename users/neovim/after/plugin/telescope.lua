local telescope = require('telescope')
telescope.setup {
    defaults = {
	file_ignore_patterns = {
	    "^experiments/",
	    -- % in lua patterns is required to escape "magic" characters
	    -- https://www.lua.org/manual/5.1/manual.html#5.4.1
	    "^record%-replay%-test%-traces/",
	    "%.git/"
	}
    },

    pickers = {
	find_files = {
	    hidden = true
	}
    }
}


local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>p', builtin.find_files, {})
vim.keymap.set('n', '<leader>ol', builtin.oldfiles, {})
vim.keymap.set('n', '<leader>ne', function()
    builtin.diagnostics({
	severity='error',
	layout_strategy='vertical'
    })
end, {})

-- lsp pickers
-- NOTE: use C-q to dump the results into the quickfix list for reference
vim.keymap.set('n', 'gd', builtin.lsp_definitions, {})
vim.keymap.set('n', 'gi', builtin.lsp_implementations, {})
vim.keymap.set('n', 'gr', builtin.lsp_references, {})
vim.keymap.set('n', '<leader>ic', builtin.lsp_incoming_calls, {})
vim.keymap.set('n', '<leader>oc', builtin.lsp_outgoing_calls, {})

-- less commonly used, maybe clean up
vim.keymap.set('n', '<leader>bu', builtin.buffers, {})
vim.keymap.set('n', '<leader>ff', function()
    builtin.live_grep({
	prompt_title = 'Find literal string...',
	additional_args = { '--fixed-strings' }
    })
end, {})
vim.keymap.set('n', '<leader>fr', function()
    builtin.live_grep({
	prompt_title = 'Find regex (via ripgrep) ...',
    })
end, {})
