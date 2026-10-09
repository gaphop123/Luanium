# Luanium

**Luanium** is a minimal Universal Web Compiler Framework written in pure Luau for Roblox executor environments. It provides HTTP transport adapters, a callback-based compile pipeline, basic parsers for HTML / CSS / JSON, language detection, a plugin registry, and resource limits.

Version: **1.0.0**

Repository structure (exactly two files):

```
luanium.luau   — complete library source (core, HTTP, parsers, plugins, API)
README.md      — this document
```

No package manifests, no extra modules, no test files, no CI configs.

---

## Load & initialize

```lua
local Luanium = loadstring(
    game:HttpGet("https://raw.githubusercontent.com/gaphop123/Luanium/main/luanium.luau")
)()

print(Luanium:GetVersion())  -- "1.0.0"
```

Replace the URL with a real raw file URL when you host the library. Luanium does **not** auto-update or execute code from untrusted sources beyond what you explicitly request via the HTTP API.

Distinguish three failure classes:

| Stage            | Typical cause                          |
|------------------|----------------------------------------|
| Load             | `HttpGet` / network / invalid Luau     |
| Init             | File does not return the `Luanium` table |
| API use          | Bad config, missing backend, limits    |

---

## HTTP Adapter

Luanium probes for common executor HTTP APIs and normalizes responses:

- `syn.request`
- `http_request`
- `request`
- `http.request`
- `game:HttpGet` (GET only)

None of these are assumed to exist. You can also register a custom transport.

### API

```lua
Luanium.HTTP:Get(url, options?, callback?)
Luanium.HTTP:Post(url, body, options?, callback?)
Luanium.HTTP:SetTransport(transportFn | nil)
Luanium.HTTP:GetCapabilities()
```

`options` may contain:

- `headers` / `Headers` — table of request headers
- `timeout` / `Timeout` — seconds (best-effort)
- `noCache` — skip GET cache

Response / callback result shape:

```lua
{
    success    = true | false,
    stage      = "http",
    output     = bodyString,          -- on success
    error      = { code, message },   -- on failure
    metadata   = {
        statusCode = number,
        headers    = table,
        fromCache  = boolean,
    },
    diagnostics = {},
    warnings    = {},
    language    = nil,
}
```

### Examples

```lua
-- GET
Luanium.HTTP:Get("https://example.com", function(res)
    if res.success then
        print(#res.output)
    else
        warn(res.error.code, res.error.message)
    end
end)

-- POST (no automatic retry)
Luanium.HTTP:Post("https://httpbin.org/post", '{"a":1}', {
    headers = { ["Content-Type"] = "application/json" },
    timeout = 15,
}, function(res)
    print(res.success, res.metadata and res.metadata.statusCode)
end)

-- Custom transport
Luanium.HTTP:SetTransport(function(method, url, headers, body, timeout)
    -- must return success, normalizedResponse or error string
    local ok, raw = pcall(syn.request, {
        Url = url, Method = method, Headers = headers, Body = body,
    })
    if not ok then return false, tostring(raw) end
    return true, raw
end)

-- Inspect
local caps = Luanium.HTTP:GetCapabilities()
-- caps.nativeTransports, caps.methods, caps.maxResponseBytes, ...
```

**Security notes**

- Only `http://` and `https://` URLs are accepted.
- POST is never auto-retried.
- Luanium does not bypass CAPTCHA, login walls, or other site protections.
- Cookies, tokens, and Roblox credentials are never stored or sent by the library.

---

## Compiler API (callback-based)

All heavy operations share a consistent result table:

```lua
{
    success     = boolean,
    language    = string | nil,
    stage       = "detect" | "parse" | "transform" | "compile" | "validate" | "fetch" | "http",
    output      = any,                 -- AST, source, IR, body, ...
    diagnostics = { { severity, message, line?, column? }, ... },
    warnings    = { ... },
    error       = { code = string, message = string } | nil,
    metadata    = table,
}
```

The callback is invoked **exactly once** (or the function returns the result synchronously). There is no built-in async cancellation or timeout of the compile pipeline itself; only HTTP may honour a transport-level timeout.

### Methods

```lua
Luanium:Compile(config, callback?)
Luanium:Parse(config, callback?)
Luanium:Transform(config, callback?)
Luanium:Validate(config, callback?)
Luanium:Fetch(url, options?, callback?)
Luanium:GetLanguages()
Luanium:GetCapabilities()
Luanium:GetVersion()
Luanium:RegisterPlugin(plugin)
Luanium:ClearCache()
```

### Config fields

| Field          | Description                                      |
|----------------|--------------------------------------------------|
| `source`       | Input source string (required for compile/parse) |
| `language`     | `"auto"` or explicit id (`html`, `css`, …)       |
| `target`       | `source` \| `ast` \| `ir` \| `luau` \| `remote`  |
| `remoteUrl`    | Required when `target = "remote"`                |
| `remoteHeaders`| Optional headers for remote backend              |
| `timeout`      | Passed to HTTP when using remote                 |

### Pipeline

```
Input → Detect → Parse → Transform → (optional Backend) → Callback
```

Luanium **never** executes the input source. It never calls `loadstring` on HTML, JavaScript, PHP, or content fetched from the network.

### Examples

```lua
-- Compile HTML → AST
Luanium:Compile({
    source   = "<div class='x'>Hello</div>",
    language = "html",
    target   = "ast",
}, function(result)
    if result.success then
        print(result.output.type)           -- "document"
        print(result.metadata.nodeCount)
    else
        warn(result.error.code, result.error.message)
        for _, d in ipairs(result.diagnostics) do
            print(d.severity, d.message, d.line)
        end
    end
end)

-- Parse CSS
Luanium:Parse({
    source = "body { color: red; } /* c */",
    language = "css",
}, function(r)
    print(r.success, r.metadata.ruleCount)
end)

-- Validate JSON
Luanium:Validate({
    source = '{"ok":true}',
    language = "json",
}, function(r)
    print(r.success)
end)

-- Remote target (user-supplied backend only)
Luanium:Compile({
    source    = "console.log(1)",
    language  = "javascript",
    target    = "remote",
    remoteUrl = "https://your-backend.example/compile",
}, function(r)
    print(r.success, r.output)
end)

-- Fetch helper (wraps HTTP GET)
Luanium:Fetch("https://example.com", function(r)
    print(r.stage, r.success)
end)
```

---

## Language support

| Language     | Detect | Parse | Transform | Compile | Notes |
|--------------|--------|-------|-----------|---------|-------|
| HTML         | ✓      | ✓     | ✓ (ast/ir/source) | ✓ | Basic tags, attributes, text, comments. Not browser-grade. |
| CSS          | ✓      | ✓     | ✓         | ✓       | Rules, selectors, declarations, comments, strings. No full at-rules/cascade. |
| JSON         | ✓      | ✓     | ✓         | ✓       | Uses `HttpService:JSONDecode/Encode` when available. |
| JavaScript   | ✓      | ✗*    | ✗         | ✗       | *Structural bracket/string check only. Full parse → plugin or remote. |
| TypeScript   | ✓      | ✗*    | ✗         | ✗       | Same limitation as JS. |
| JSX / TSX    | ✓      | ✗     | ✗         | ✗       | Detection heuristic only. |
| PHP          | ✓      | ✗     | ✗         | ✗       | Recognition only. No PHP runtime. |
| Markdown     | ✓      | ✗     | ✗         | ✗       | Extend via plugin. |
| YAML         | ✓      | ✗     | ✗         | ✗       | Extend via plugin. |
| XML          | ✓      | ✗     | ✗         | ✗       | Extend via plugin. |

When a backend or full parser is missing the result uses:

- `error.code = "BACKEND_UNAVAILABLE"` or `"PARSER_UNAVAILABLE"`

Regex is **not** treated as a substitute for a real JavaScript/TypeScript parser. HTML/CSS/JS/React/PHP cannot be executed inside Luau by this library.

---

## Plugin system

Register plugins at runtime:

```lua
local ok, err = Luanium:RegisterPlugin({
    name         = "Example",
    version      = "1.0.0",
    languages    = { "example" },
    capabilities = {
        detect    = true,
        parse     = true,
        transform = false,
        compile   = false,
    },
    detect = function(source, config)
        return "example"
    end,
    parse = function(source, config)
        return {
            success     = true,
            language    = "example",
            stage       = "parse",
            output      = { type = "example-ast", length = #source },
            diagnostics = {},
            warnings    = {},
            error       = nil,
            metadata    = {},
        }
    end,
})
```

Rules:

- `name`, `version`, `languages`, `capabilities` are required.
- If `capabilities.parse/transform/compile` is `true`, the matching function must exist.
- Invalid plugins are rejected; undeclared capabilities are never advertised.
- Built-in language entries are extended when a plugin supplies new languages.

---

## Cache & resource limits

Defaults (tunable only by editing the library constants):

| Limit                    | Default        |
|--------------------------|----------------|
| Max source size          | 2 MiB          |
| Max HTTP response size   | 4 MiB          |
| Max cache entries        | 32             |
| Max cache bytes          | 8 MiB          |
| Max requests / session   | 64             |
| Request timeout          | 30 s           |

- GET responses may be cached; POST is never cached.
- `Luanium:ClearCache()` drops the in-memory cache.
- Nested dependency resolution of arbitrary depth is not performed.
- Remote fetch can be conceptually disabled by the `allowRemoteFetch` default (true in this build).

---

## Executor-dependent APIs

| Feature              | Depends on                                      |
|----------------------|-------------------------------------------------|
| Full HTTP GET/POST   | `syn.request` / `http_request` / `request` / `http.request` |
| GET fallback         | `game:HttpGet`                                  |
| JSON parse/serialize | `game:GetService("HttpService")`                |
| Custom transport     | Your own function                               |

Call `Luanium.HTTP:GetCapabilities()` and `Luanium:GetCapabilities()` at runtime to see what is actually available in the current executor. The library does not claim universal executor support.

---

## Technical & security limits

1. **No code execution** of HTML, JavaScript, PHP, TypeScript, or any fetched payload.
2. **No `loadstring`** on untrusted content.
3. **No auth bypass**, CAPTCHA solving, or cookie/token harvesting.
4. **No automatic POST retry**.
5. **Partial parsers only** for HTML/CSS; JS/TS are structural checks.
6. **Remote backends** are entirely under user control (`target = "remote"` + `remoteUrl`).
7. **Single-file distribution** — no external Luau modules are required at runtime.
8. Callback is called once; there is no pipeline-level cancellation API.

---

## Quick reference

```lua
local Luanium = loadstring(game:HttpGet("https://raw.githubusercontent.com/OWNER/Luanium/main/luanium.luau"))()

-- Version & capabilities
print(Luanium:GetVersion())
local caps = Luanium:GetCapabilities()

-- HTTP
Luanium.HTTP:Get("https://example.com", function(r) print(r.success) end)

-- Compile
Luanium:Compile({
    source   = "<p>Hi</p>",
    language = "html",
    target   = "ast",
}, function(r)
    assert(r.success)
    print(r.output.type)
end)

-- Plugin
Luanium:RegisterPlugin({ ... })

-- Cleanup
Luanium:ClearCache()
```

---

## License / distribution

Ship only the two files. Host `luanium.luau` at any raw URL you control. Do not claim features that the single-file implementation does not provide.
