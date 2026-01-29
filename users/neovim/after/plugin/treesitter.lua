-- https://github.com/nvim-treesitter/nvim-treesitter#highlighting
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('treesitter-highlight', { clear = true }),
  pattern = '*',
  callback = function(event)
    pcall(vim.treesitter.start, event.buf, event.match)
  end
})
