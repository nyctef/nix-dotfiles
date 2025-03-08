vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local opts = { buffer = args.buf }

    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)

    vim.keymap.set({'n', 'x'}, 'gq', function() vim.lsp.buf.format({async = false, timeout_ms = 3000}) end, opts)
    vim.keymap.set({'n', 'x'}, 'ga', vim.lsp.buf.code_action, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.rename, opts)

  end,
})


-- see also: after/plugin/telescope.lua
