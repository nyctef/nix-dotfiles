/**
 * Web Search Tool - Brave Search API
 *
 * Requires the BRAVE_SEARCH_API_KEY environment variable to be set.
 * Get a free API key (2000 req/month) at https://api.search.brave.com
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface BraveSearchResult {
  title: string;
  url: string;
  description?: string;
  age?: string;
}

interface BraveSearchResponse {
  web?: {
    results?: BraveSearchResult[];
  };
  query?: {
    original?: string;
    altered?: string;
  };
}

const webSearchTool = defineTool({
  name: "web_search",
  label: "Web Search",
  description:
    "Search the web for current information using Brave Search. Use this for recent events, documentation, package versions, or anything that may have changed since the training cutoff.",
  promptSnippet: "Search the web for up-to-date information",
  parameters: Type.Object({
    query: Type.String({ description: "The search query" }),
    count: Type.Optional(
      Type.Number({
        description: "Number of results to return (1-10, default 5)",
        minimum: 1,
        maximum: 10,
      }),
    ),
  }),

  async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
    const apiKey = process.env.BRAVE_SEARCH_API_KEY;

    if (!apiKey) {
      return {
        content: [
          {
            type: "text",
            text: "Web search is not available: BRAVE_SEARCH_API_KEY environment variable is not set.",
          },
        ],
        isError: true,
      };
    }

    const count = params.count ?? 5;
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.searchParams.set("q", params.query);
    url.searchParams.set("count", String(count));

    let response: Response;
    try {
      response = await fetch(url.toString(), {
        headers: {
          "X-Subscription-Token": apiKey,
          Accept: "application/json",
          "Accept-Encoding": "gzip",
        },
        signal,
      });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text", text: `Web search request failed: ${message}` }],
        isError: true,
      };
    }

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return {
        content: [
          {
            type: "text",
            text: `Brave Search API error ${response.status}: ${body || response.statusText}`,
          },
        ],
        isError: true,
      };
    }

    const data = (await response.json()) as BraveSearchResponse;
    const results = data.web?.results ?? [];

    if (results.length === 0) {
      return {
        content: [{ type: "text", text: `No results found for: ${params.query}` }],
      };
    }

    const alteredNote =
      data.query?.altered && data.query.altered !== data.query.original
        ? `\n> Query interpreted as: "${data.query.altered}"\n`
        : "";

    const formatted = results
      .map((r, i) => {
        const age = r.age ? ` (${r.age})` : "";
        const desc = r.description ? `\n   ${r.description}` : "";
        return `${i + 1}. **${r.title}**${age}\n   ${r.url}${desc}`;
      })
      .join("\n\n");

    return {
      content: [
        {
          type: "text",
          text: `Search results for "${params.query}":${alteredNote}\n\n${formatted}`,
        },
      ],
      details: { resultCount: results.length, query: params.query },
    };
  },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool(webSearchTool);
}
