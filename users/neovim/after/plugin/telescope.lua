local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>p', builtin.find_files, {})
vim.keymap.set('n', '<leader>bu', builtin.buffers, {})
vim.keymap.set('n', '<leader>ol', builtin.oldfiles, {})
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
vim.keymap.set('n', '<leader>ne', function()
    builtin.diagnostics({
	severity='error',
	layout_strategy='vertical'
    })
end, {})

