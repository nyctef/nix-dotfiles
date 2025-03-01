" lua require('keybinds')

" lua require('plugins')

" auto set the current working dir to match the current file
" set autochdir

" smarter case-sensitivity in searches
set ignorecase
set smartcase

syntax on
colorscheme onehalfdark

" set space for the gutter even if nothing's using it
set signcolumn=yes

" line numbers
set number

" don't keep highlighting search results once the search is done
set nohlsearch

" longest: only complete to the longest common subsequence instead of greedily
" picking an option
" menuone: open the completion menu even when there's only one result
set completeopt=longest,menuone
set wildmode=list:longest
set wildmenu
set wildoptions=pum

" prefer unix line endings, even on windows
set fileformats=unix,dos

" Disable default map for S-K: https://github.com/neovim/neovim/issues/21169
map K <Nop>

" make sure errors take priority if there are multiple diagnostics on one line
lua vim.diagnostic.config({ severity_sort = true })

" make sure there's always some context around the cursor
set scrolloff=8

language en_US

" allow opening .exrc or .nvimrc files in the current directory (with a prompt)
set exrc

