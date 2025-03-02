require('roslyn').setup({

	exe = 'Microsoft.CodeAnalysis.LanguageServer',

	-- TODO: figure out how to make file watching work properly
	-- currently if we leave filewatching=true here, then roslyn tries
	-- to use its own file watcher which consumes a million inotify
	-- instances / file descriptors and blows up
	--
	-- is there a way to use neovim's file watching instead (something
	-- to do with didChangeWatchedFiles?)
	filewatching = false,

});
