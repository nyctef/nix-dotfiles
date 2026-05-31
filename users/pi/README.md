# pi configuration

Pi extensions and home-manager module for [pi coding agent](https://pi.dev).

## Web search (`websearch.ts`)

Registers a `web_search` tool using the [Brave Search API](https://api.search.brave.com).

### Setup

1. Get a free API key at <https://api.search.brave.com> (2000 req/month on the free tier)

2. Encrypt it with agenix:
   ```sh
   cd ~/.dotfiles
   echo -n "YOUR_API_KEY_HERE" | agenix -e secrets/brave-search-api-key.age
   ```

3. Rebuild:
   ```sh
   apply-users
   ```

The extension is auto-enabled when `secrets/brave-search-api-key.age` exists, and
silently skipped otherwise — so builds work on machines that don't have the key.
