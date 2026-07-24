# Subgraph MCP — the 2nd composed Graph product

Baywatch Radar clears the bounty's "compose 2+ Graph products" gate with **standardized subgraph + Subgraph
MCP**. The standardized Messari DEX-AMM schema gives the shared query shape; the **Subgraph MCP** discovers
the deployments and orchestrates the cross-venue fan-out.

## What the MCP adds

The public gateway has no cross-deployment federation — each AMM is its own `subgraphId`. The MCP is what
makes "ask once, answer across every AMM" real:

1. **Resolve** the `subgraphId: null` entries in `venues.json` — `search_subgraphs_by_keyword("uniswap v2
   messari dex amm")` returns candidate deployments; `get_top_subgraph_deployments` ranks by query volume.
2. **Verify** the schema is the standardized one — `get_schema_by_subgraph_id` confirms the `Swap` /
   `LiquidityPool` fields the Radar depends on.
3. **Fan out** the identical `query.graphql` across every resolved deployment —
   `execute_query_by_subgraph_id` per venue. Same shape, N venues → one toxicity leaderboard.

The MCP and the gateway share **one credential** (`GRAPH_API_KEY` from Subgraph Studio), so nothing extra
to provision beyond the single key.

## Connect (hosted)

The MCP is a shipped, hosted product. Add it to any MCP client (Claude Code, Cursor, Claude Desktop) via
`mcp-remote`:

```jsonc
// .mcp.json / client MCP config
{
  "mcpServers": {
    "subgraph": {
      "command": "npx",
      "args": [
        "mcp-remote", "https://subgraphs.mcp.thegraph.com/sse",
        "--header", "Authorization: Bearer ${GRAPH_API_KEY}"
      ]
    }
  }
}
```

Self-host alternative: `graphops/subgraph-mcp` (Rust) with `GATEWAY_API_KEY` set.

## Division of labor

| Path | Product | Role |
|---|---|---|
| interactive / discovery | **Subgraph MCP** | resolve `subgraphId`s, verify standardized schema, ad-hoc cross-venue Q&A |
| automated agent loop | **gateway** (`radar/fetch.mjs`) | the same query.graphql fanned across the resolved deployments every scan |

Both consume live data from The Graph with the same key. The MCP-resolved `subgraphId`s get written back into
`venues.json`, after which `radar/probe.mjs` gates each on `_meta` freshness (live-data qualification).

## Demo script (with a key)

```bash
export GRAPH_API_KEY=<studio key>
node radar/probe.mjs      # which standardized deployments are live vs stale (ride-public vs self-deploy)
node radar/signal.mjs     # fan the standardized query across live venues -> toxicity leaderboard
# then the same closed loop as the offline demo:
bash radar/e2e.sh
```
