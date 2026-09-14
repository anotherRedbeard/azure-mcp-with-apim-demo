# CrowdStrike AIDR "AI Guard" policy - MCP variants

This folder contains two modified copies of CrowdStrike's global APIM policy
for their AI Detection and Response (AIDR) "AI Guard" product:

- Upstream: <https://github.com/CrowdStrike/aidr-azure-api-management/blob/main/ai-guard-policy.xml>
- [`ai-guard-policy-mcp-safe.xml`](./ai-guard-policy-mcp-safe.xml) - **safe**
  variant: prevents the policy from breaking MCP traffic, but does not send
  MCP content to CrowdStrike.
- [`ai-guard-policy-mcp-aware.xml`](./ai-guard-policy-mcp-aware.xml) - **aware**
  variant: everything the safe variant does, *plus* it recognizes MCP
  (JSON-RPC) traffic and sends tool call input/output to CrowdStrike for
  logging and blocking, the same as OpenAI-shaped traffic.

Pick whichever matches what you want: just keep MCP traffic working, or
actually get CrowdStrike visibility into MCP tool calls too.

## Why a modified copy at all?

The upstream policy assumes every request/response is shaped like the Azure
OpenAI **Responses API** (`input` / `instructions` / `model` on the request,
an `output` array of assistant messages on the response). If applied
globally (all APIs), it will also run against MCP traffic - which uses
JSON-RPC 2.0 and, for streamable-HTTP transports, typically returns
`Content-Type: text/event-stream` (SSE) responses rather than a JSON object.

- **Inbound** already no-ops safely for MCP in the upstream policy: the
  JSON-RPC body parses fine as JSON, but none of `input`/`instructions`/
  `model` exist, so the guard call is skipped.
- **Outbound** is the risk: the upstream policy unconditionally calls
  `context.Response.Body.As<JObject>()` with no content-type check and no
  error handling. Parsing an SSE stream as JSON throws, and the built-in
  `<on-error>` just traces and re-throws - breaking the MCP response for the
  client.

## `ai-guard-policy-mcp-safe.xml`

Only the `<outbound>` section is modified vs. upstream, with two layers of
defense so non-JSON (e.g., MCP SSE) responses are skipped cleanly instead of
erroring:

1. **Content-Type check** - only attempt to parse the body as JSON when the
   response header says `application/json`.
2. **Try/catch inside the parse itself** - a safety net for responses that
   are mislabeled or otherwise not valid JSON.

Every other API (e.g., an Azure OpenAI passthrough API) keeps the original
CrowdStrike guard/logging/blocking behavior, byte-for-byte, unchanged. MCP
traffic passes through untouched - no logging, no blocking, no errors.

## `ai-guard-policy-mcp-aware.xml`

Starts from the safe variant and extends the extraction logic (minimally) so
MCP (JSON-RPC) traffic is recognized and sent through the *same* CrowdStrike
guard call as OpenAI-shaped traffic, instead of just being ignored:

1. **Inbound** - when the request body has no `input`/`instructions` (i.e. it
   isn't OpenAI-shaped) but is a JSON-RPC `tools/call` request, the tool name
   + arguments are sent to CrowdStrike as the "user" message content. The
   `model` tag is set to `mcp:<method>[:<tool>]` so entries are identifiable
   in CrowdStrike's logs.
2. **Outbound** - the response is parsed as JSON (OpenAI shape) **or**, if
   the response is a streamable-HTTP SSE (`Content-Type: text/event-stream`),
   the JSON-RPC message is pulled out of the `data:` line. Either way, the
   assistant/tool-result text is extracted from `output` (OpenAI) or
   `result.content` (MCP) and sent to CrowdStrike as the "assistant" message.
   Any parse failure (mismatched shape, partial/invalid body) falls back to
   `null` and is skipped cleanly instead of throwing.

Both directions still run through CrowdStrike's existing blocking check
(a 403 is returned if `blocked: true` comes back), so MCP tool calls/results
get the same logging **and** enforcement as OpenAI traffic.

**Intentionally out of scope (kept minimal):** the upstream policy's
*content-transform/rewrite* logic (when CrowdStrike returns `transformed:
true` with replacement text) is left untouched. It only looks for the
OpenAI `input`/`output` shape, so for MCP traffic it naturally no-ops -
blocking still works, but CrowdStrike-rewritten MCP tool arguments/results
are not rewritten back into the JSON-RPC message. Doing that reliably
(especially for the SSE case) would add real complexity for a demo repo;
extend it if you need that.

### Limitations

- The SSE parser reads the **first** `data:` line that contains a
  `result`/`error` field. This matches how this repo's MCP server responds to
  a single tool call (one JSON-RPC message per response stream). A server
  that multiplexes several JSON-RPC messages onto one long-lived SSE stream
  (e.g., server-initiated notifications) would need a more complete
  line-by-line accumulator - out of scope for this minimal change.
- Only `tools/call` requests are inspected on the inbound side. Other MCP
  methods (`initialize`, `tools/list`, `resources/*`, etc.) carry no
  user-authored content worth guarding and are left as no-ops, same as
  before.