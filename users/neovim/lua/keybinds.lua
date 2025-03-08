vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local opts = { buffer = args.buf }

    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    -- vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts) -- try to use <C-]> instead

    vim.keymap.set({'n', 'x'}, 'gq', function() vim.lsp.buf.format({async = false, timeout_ms = 3000}) end, opts)
    vim.keymap.set({'n', 'x'}, 'ga', vim.lsp.buf.code_action, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.rename, opts)

  end,
})

-- make ESC work as expected in terminal mode
vim.keymap.set('t', '<ESC>', '<C-\\><C-n>');


-- see also: after/plugin/telescope.lua
