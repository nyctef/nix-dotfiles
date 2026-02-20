require('roslyn').setup({

	-- use "off" to disable roslyn's built-in file watcher which
	-- consumes too many inotify instances / file descriptors.
	-- neovim's didChangeWatchedFiles is used instead.
	filewatching = "off",

});
