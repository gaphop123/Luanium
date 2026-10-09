--[[
    Luanium v1.0.0
    Universal Web Compiler Framework for Roblox executors
    Single-file library. All modules, adapters, parsers and plugin system live here.
    Designed for executor environments that may expose request / http_request / syn.request / http.request / game:HttpGet.
]]

local Luanium = {
    _VERSION = "1.0.0",
    _NAME = "Luanium",
}

--------------------------------------------------------------------------------
-- Internal utilities
--------------------------------------------------------------------------------

local function shallowCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do
        r[k] = v
    end
    return r
end

local function deepCopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local r = {}
    seen[t] = r
    for k, v in pairs(t) do
        r[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return r
end

local function isString(v) return type(v) == "string" end
local function isTable(v) return type(v) == "table" end
local function isFunction(v) return type(v) == "function" end
local function isNumber(v) return type(v) == "number" end

local function safeCall(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then
        return true, a, b, c, d
    end
    return false, tostring(a)
end

local function makeResult(opts)
    opts = opts or {}
    return {
        success = opts.success == true,
        language = opts.language or nil,
        stage = opts.stage or nil,
        output = opts.output,
        diagnostics = opts.diagnostics or {},
        warnings = opts.warnings or {},
        error = opts.error or nil,
        metadata = opts.metadata or {},
    }
end

local function addDiagnostic(list, severity, message, line, column)
    list = list or {}
    table.insert(list, {
        severity = severity or "error",
        message = tostring(message or ""),
        line = line,
        column = column,
    })
    return list
end

--------------------------------------------------------------------------------
-- Configuration & limits
--------------------------------------------------------------------------------

local DEFAULTS = {
    maxSourceBytes = 2 * 1024 * 1024,      -- 2 MiB source limit
    maxResponseBytes = 4 * 1024 * 1024,    -- 4 MiB HTTP response limit
    maxCacheEntries = 32,
    maxCacheBytes = 8 * 1024 * 1024,
    maxRequestsPerSession = 64,
    requestTimeout = 30,
    allowCache = true,
    allowRemoteFetch = true,
}

local state = {
    requestCount = 0,
    cache = {},          -- key -> { value, size, ts }
    cacheBytes = 0,
    plugins = {},        -- name -> plugin table
    transport = nil,     -- custom HTTP transport
    capabilities = nil,  -- cached capability snapshot
}

--------------------------------------------------------------------------------
-- Cache helpers
--------------------------------------------------------------------------------

local function cacheKey(kind, key)
    return tostring(kind) .. "|" .. tostring(key)
end

local function cacheGet(kind, key)
    if not DEFAULTS.allowCache then return nil end
    local k = cacheKey(kind, key)
    local e = state.cache[k]
    if e then
        e.ts = os.clock()
        return e.value
    end
    return nil
end

local function cacheSet(kind, key, value, size)
    if not DEFAULTS.allowCache then return end
    size = size or (isString(value) and #value or 256)
    if size > DEFAULTS.maxCacheBytes then return end

    -- Evict oldest if needed
    while (state.cacheBytes + size > DEFAULTS.maxCacheBytes)
        or (function()
            local n = 0
            for _ in pairs(state.cache) do n = n + 1 end
            return n >= DEFAULTS.maxCacheEntries
        end)() do
        local oldestKey, oldestTs = nil, math.huge
        for k, e in pairs(state.cache) do
            if e.ts < oldestTs then
                oldestTs = e.ts
                oldestKey = k
            end
        end
        if not oldestKey then break end
        state.cacheBytes = state.cacheBytes - (state.cache[oldestKey].size or 0)
        state.cache[oldestKey] = nil
    end

    local k = cacheKey(kind, key)
    if state.cache[k] then
        state.cacheBytes = state.cacheBytes - (state.cache[k].size or 0)
    end
    state.cache[k] = { value = value, size = size, ts = os.clock() }
    state.cacheBytes = state.cacheBytes + size
end

local function clearCache()
    state.cache = {}
    state.cacheBytes = 0
end

--------------------------------------------------------------------------------
-- HTTP Adapter
--------------------------------------------------------------------------------

local HTTP = {}

local function detectNativeTransports()
    local found = {}
    -- syn.request (Synapse / many forks)
    if type(syn) == "table" and isFunction(syn.request) then
        table.insert(found, "syn.request")
    end
    -- http_request (common alias)
    if isFunction(http_request) then
        table.insert(found, "http_request")
    end
    -- request (Fluxus / some)
    if isFunction(request) then
        table.insert(found, "request")
    end
    -- http.request (some environments)
    if type(http) == "table" and isFunction(http.request) then
        table.insert(found, "http.request")
    end
    -- game:HttpGet (Roblox native, GET only, limited)
    if game and isFunction(game.HttpGet) then
        table.insert(found, "game:HttpGet")
    end
    return found
end

local function normalizeResponse(raw)
    -- Accept various shapes from different executors and normalize.
    if not isTable(raw) then
        return {
            Success = false,
            StatusCode = 0,
            StatusMessage = "Invalid response",
            Headers = {},
            Body = "",
        }
    end
    local status = raw.StatusCode or raw.statusCode or raw.status or raw.Status or 0
    local body = raw.Body or raw.body or raw.Data or raw.data or ""
    local headers = raw.Headers or raw.headers or {}
    local success = raw.Success
    if success == nil then
        success = (type(status) == "number" and status >= 200 and status < 300)
    end
    local msg = raw.StatusMessage or raw.statusMessage or raw.Message or ""
    return {
        Success = success == true,
        StatusCode = tonumber(status) or 0,
        StatusMessage = tostring(msg),
        Headers = headers,
        Body = tostring(body),
    }
end

local function callNativeRequest(method, url, headers, body, timeout)
    local transports = detectNativeTransports()
    local opts = {
        Url = url,
        Method = method,
        Headers = headers or {},
        Body = body,
    }
    if timeout then
        opts.Timeout = timeout
    end

    for _, name in ipairs(transports) do
        if name == "syn.request" then
            local ok, res = pcall(syn.request, opts)
            if ok then return true, normalizeResponse(res) end
        elseif name == "http_request" then
            local ok, res = pcall(http_request, opts)
            if ok then return true, normalizeResponse(res) end
        elseif name == "request" then
            local ok, res = pcall(request, opts)
            if ok then return true, normalizeResponse(res) end
        elseif name == "http.request" then
            local ok, res = pcall(http.request, opts)
            if ok then return true, normalizeResponse(res) end
        elseif name == "game:HttpGet" and method == "GET" then
            -- game:HttpGet is GET-only and returns body string (or errors)
            local ok, bodyOrErr = pcall(function()
                return game:HttpGet(url, true)
            end)
            if ok then
                return true, {
                    Success = true,
                    StatusCode = 200,
                    StatusMessage = "OK",
                    Headers = {},
                    Body = tostring(bodyOrErr),
                }
            else
                return false, tostring(bodyOrErr)
            end
        end
    end
    return false, "No compatible HTTP transport available"
end

local function validateUrl(url)
    if not isString(url) or #url == 0 then
        return false, "URL must be a non-empty string"
    end
    local lower = string.lower(url)
    if not (string.sub(lower, 1, 7) == "http://" or string.sub(lower, 1, 8) == "https://") then
        return false, "Only http:// and https:// URLs are allowed"
    end
    -- Basic length guard
    if #url > 2048 then
        return false, "URL too long"
    end
    return true
end

local function enforceLimits(url)
    if state.requestCount >= DEFAULTS.maxRequestsPerSession then
        return false, "Request limit reached for this session"
    end
    local ok, err = validateUrl(url)
    if not ok then return false, err end
    return true
end

function HTTP:GetCapabilities()
    local natives = detectNativeTransports()
    return {
        nativeTransports = natives,
        customTransport = state.transport ~= nil,
        methods = (function()
            local m = { "GET" }
            -- POST only if a full request API exists
            for _, n in ipairs(natives) do
                if n ~= "game:HttpGet" then
                    table.insert(m, "POST")
                    break
                end
            end
            if state.transport then
                if not table.find(m, "POST") then table.insert(m, "POST") end
            end
            return m
        end)(),
        maxResponseBytes = DEFAULTS.maxResponseBytes,
        timeoutSupported = true, -- best-effort; depends on transport
        headersSupported = true,
    }
end

function HTTP:SetTransport(transport)
    if transport == nil then
        state.transport = nil
        return true
    end
    if not isFunction(transport) then
        return false, "Transport must be a function(method, url, headers, body, timeout) -> success, responseOrError"
    end
    state.transport = transport
    return true
end

local function doRequest(method, url, body, options, callback)
    options = options or {}
    local headers = options.headers or options.Headers or {}
    local timeout = options.timeout or options.Timeout or DEFAULTS.requestTimeout

    local function fail(msg, extra)
        local res = makeResult({
            success = false,
            stage = "http",
            error = {
                code = "HTTP_ERROR",
                message = tostring(msg),
            },
            metadata = extra or {},
        })
        if isFunction(callback) then
            callback(res)
        end
        return res
    end

    local okLimit, errLimit = enforceLimits(url)
    if not okLimit then
        return fail(errLimit)
    end

    -- Cache GET only
    if method == "GET" and DEFAULTS.allowCache and not options.noCache then
        local cached = cacheGet("http", method .. ":" .. url)
        if cached then
            local res = makeResult({
                success = true,
                stage = "http",
                output = cached.Body,
                metadata = {
                    statusCode = cached.StatusCode,
                    headers = cached.Headers,
                    fromCache = true,
                },
            })
            if isFunction(callback) then callback(res) end
            return res
        end
    end

    state.requestCount = state.requestCount + 1

    local ok, result
    if state.transport then
        ok, result = pcall(state.transport, method, url, headers, body, timeout)
        if not ok then
            return fail("Custom transport error: " .. tostring(result))
        end
        if type(result) == "table" and result.Success ~= nil then
            result = normalizeResponse(result)
        elseif type(result) == "string" then
            -- transport returned body only
            result = {
                Success = true,
                StatusCode = 200,
                StatusMessage = "OK",
                Headers = {},
                Body = result,
            }
        else
            return fail("Custom transport returned unexpected value")
        end
    else
        ok, result = callNativeRequest(method, url, headers, body, timeout)
        if not ok then
            return fail(result)
        end
    end

    if not result.Success then
        return fail("HTTP " .. tostring(result.StatusCode) .. " " .. tostring(result.StatusMessage), {
            statusCode = result.StatusCode,
            headers = result.Headers,
        })
    end

    local bodyStr = result.Body or ""
    if #bodyStr > DEFAULTS.maxResponseBytes then
        return fail("Response exceeds maxResponseBytes limit (" .. DEFAULTS.maxResponseBytes .. ")")
    end

    if method == "GET" and DEFAULTS.allowCache and not options.noCache then
        cacheSet("http", method .. ":" .. url, result, #bodyStr)
    end

    local res = makeResult({
        success = true,
        stage = "http",
        output = bodyStr,
        metadata = {
            statusCode = result.StatusCode,
            headers = result.Headers,
            fromCache = false,
        },
    })
    if isFunction(callback) then callback(res) end
    return res
end

function HTTP:Get(url, options, callback)
    if isFunction(options) and callback == nil then
        callback = options
        options = {}
    end
    return doRequest("GET", url, nil, options or {}, callback)
end

function HTTP:Post(url, body, options, callback)
    if isFunction(options) and callback == nil then
        callback = options
        options = {}
    end
    body = body or ""
    if not isString(body) then
        body = tostring(body)
    end
    -- No automatic retry for POST
    return doRequest("POST", url, body, options or {}, callback)
end

Luanium.HTTP = HTTP

--------------------------------------------------------------------------------
-- Language detection (heuristic)
--------------------------------------------------------------------------------

local function detectLanguage(source, hint)
    if isString(hint) and hint ~= "" and hint ~= "auto" then
        return string.lower(hint)
    end
    if not isString(source) or #source == 0 then
        return "unknown"
    end
    local s = source
    local trimmed = string.match(s, "^%s*(.-)%s*$") or s

    -- JSON
    if (string.sub(trimmed, 1, 1) == "{" or string.sub(trimmed, 1, 1) == "[") then
        local ok = pcall(function()
            if game and game.HttpService then
                game.HttpService:JSONDecode(trimmed)
            else
                -- minimal check
                assert(string.find(trimmed, "[{%[]"))
            end
        end)
        if ok then return "json" end
    end

    -- HTML
    if string.find(trimmed, "^%s*<!DOCTYPE%s+[Hh][Tt][Mm][Ll]")
        or string.find(trimmed, "^%s*<[Hh][Tt][Mm][Ll]")
        or (string.find(trimmed, "<%s*[a-zA-Z]") and string.find(trimmed, "</")) then
        return "html"
    end

    -- CSS (rough)
    if string.find(trimmed, "[%a%-]+%s*{[^}]*}") and not string.find(trimmed, "function%s*%(") then
        return "css"
    end

    -- PHP
    if string.find(trimmed, "<%?php") or string.find(trimmed, "<%?=") then
        return "php"
    end

    -- JSX / TSX heuristic
    if string.find(trimmed, "<%s*[A-Z]%w*") and (string.find(trimmed, "import%s+") or string.find(trimmed, "export%s+") or string.find(trimmed, "React")) then
        if string.find(trimmed, ":%s*%w+") and string.find(trimmed, "interface%s+") then
            return "tsx"
        end
        return "jsx"
    end

    -- TypeScript
    if string.find(trimmed, "interface%s+%w+") or string.find(trimmed, "type%s+%w+%s*=") or string.find(trimmed, ":%s*(string|number|boolean|any)") then
        return "typescript"
    end

    -- JavaScript
    if string.find(trimmed, "function%s*%(") or string.find(trimmed, "=>") or string.find(trimmed, "const%s+") or string.find(trimmed, "let%s+") or string.find(trimmed, "var%s+") then
        return "javascript"
    end

    -- Markdown
    if string.find(trimmed, "^#%s+") or string.find(trimmed, "%[%w+%]%([^%)]+%)") then
        return "markdown"
    end

    -- YAML
    if string.find(trimmed, "^[%w_-]+%s*:") and not string.find(trimmed, "{") then
        return "yaml"
    end

    -- XML
    if string.find(trimmed, "^%s*<%?xml") or (string.find(trimmed, "<%w+") and string.find(trimmed, "</%w+>")) then
        return "xml"
    end

    return "unknown"
end

--------------------------------------------------------------------------------
-- Token helpers (shared)
--------------------------------------------------------------------------------

local function makeLexer(source)
    local pos = 1
    local len = #source
    local line = 1
    local col = 1

    local function peek(n)
        n = n or 0
        return string.sub(source, pos + n, pos + n)
    end

    local function advance()
        local c = string.sub(source, pos, pos)
        pos = pos + 1
        if c == "\n" then
            line = line + 1
            col = 1
        else
            col = col + 1
        end
        return c
    end

    local function match(str)
        local s = string.sub(source, pos, pos + #str - 1)
        if s == str then
            for i = 1, #str do advance() end
            return true
        end
        return false
    end

    local function skipWhitespace()
        while pos <= len do
            local c = peek()
            if c == " " or c == "\t" or c == "\r" or c == "\n" then
                advance()
            else
                break
            end
        end
    end

    return {
        source = source,
        pos = function() return pos end,
        line = function() return line end,
        col = function() return col end,
        peek = peek,
        advance = advance,
        match = match,
        skipWhitespace = skipWhitespace,
        eof = function() return pos > len end,
        len = len,
    }
end

--------------------------------------------------------------------------------
-- HTML Parser (basic)
--------------------------------------------------------------------------------

local HtmlParser = {}

function HtmlParser.tokenize(source)
    local tokens = {}
    local lex = makeLexer(source)
    while not lex.eof() do
        local c = lex.peek()
        if c == "<" then
            local startLine, startCol = lex.line(), lex.col()
            lex.advance() -- <
            if lex.match("!--") then
                -- comment
                local buf = ""
                while not lex.eof() and not lex.match("-->") do
                    buf = buf .. lex.advance()
                end
                table.insert(tokens, { type = "comment", value = buf, line = startLine, column = startCol })
            elseif lex.peek() == "/" then
                lex.advance()
                local name = ""
                while not lex.eof() do
                    local ch = lex.peek()
                    if ch == ">" or ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then break end
                    name = name .. lex.advance()
                end
                while not lex.eof() and lex.peek() ~= ">" do lex.advance() end
                if lex.peek() == ">" then lex.advance() end
                table.insert(tokens, { type = "end_tag", name = string.lower(name), line = startLine, column = startCol })
            else
                local name = ""
                while not lex.eof() do
                    local ch = lex.peek()
                    if ch == ">" or ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "/" then break end
                    name = name .. lex.advance()
                end
                local attrs = {}
                while not lex.eof() do
                    lex.skipWhitespace()
                    if lex.peek() == ">" or lex.peek() == "/" then break end
                    local aname = ""
                    while not lex.eof() do
                        local ch = lex.peek()
                        if ch == "=" or ch == " " or ch == ">" or ch == "/" or ch == "\t" or ch == "\n" then break end
                        aname = aname .. lex.advance()
                    end
                    if aname == "" then break end
                    lex.skipWhitespace()
                    local aval = true
                    if lex.peek() == "=" then
                        lex.advance()
                        lex.skipWhitespace()
                        aval = ""
                        local q = lex.peek()
                        if q == '"' or q == "'" then
                            lex.advance()
                            while not lex.eof() and lex.peek() ~= q do
                                aval = aval .. lex.advance()
                            end
                            if lex.peek() == q then lex.advance() end
                        else
                            while not lex.eof() do
                                local ch = lex.peek()
                                if ch == " " or ch == ">" or ch == "/" or ch == "\t" or ch == "\n" then break end
                                aval = aval .. lex.advance()
                            end
                        end
                    end
                    attrs[string.lower(aname)] = aval
                end
                local selfClosing = false
                if lex.peek() == "/" then
                    lex.advance()
                    selfClosing = true
                end
                if lex.peek() == ">" then lex.advance() end
                table.insert(tokens, {
                    type = "start_tag",
                    name = string.lower(name),
                    attrs = attrs,
                    selfClosing = selfClosing,
                    line = startLine,
                    column = startCol,
                })
            end
        else
            local startLine, startCol = lex.line(), lex.col()
            local buf = ""
            while not lex.eof() and lex.peek() ~= "<" do
                buf = buf .. lex.advance()
            end
            if string.match(buf, "%S") then
                table.insert(tokens, { type = "text", value = buf, line = startLine, column = startCol })
            end
        end
    end
    return tokens
end

function HtmlParser.parse(source)
    local tokens = HtmlParser.tokenize(source)
    local root = { type = "document", children = {}, name = "#document" }
    local stack = { root }
    local diagnostics = {}

    local voidTags = {
        area=true, base=true, br=true, col=true, embed=true, hr=true,
        img=true, input=true, link=true, meta=true, param=true, source=true,
        track=true, wbr=true,
    }

    for _, tok in ipairs(tokens) do
        if tok.type == "start_tag" then
            local node = {
                type = "element",
                name = tok.name,
                attrs = tok.attrs or {},
                children = {},
                line = tok.line,
                column = tok.column,
            }
            local parent = stack[#stack]
            table.insert(parent.children, node)
            if not tok.selfClosing and not voidTags[tok.name] then
                table.insert(stack, node)
            end
        elseif tok.type == "end_tag" then
            local found = false
            for i = #stack, 2, -1 do
                if stack[i].name == tok.name then
                    while #stack >= i do table.remove(stack) end
                    found = true
                    break
                end
            end
            if not found then
                addDiagnostic(diagnostics, "warning", "Unexpected closing tag </" .. tok.name .. ">", tok.line, tok.column)
            end
        elseif tok.type == "text" then
            table.insert(stack[#stack].children, {
                type = "text",
                value = tok.value,
                line = tok.line,
                column = tok.column,
            })
        elseif tok.type == "comment" then
            table.insert(stack[#stack].children, {
                type = "comment",
                value = tok.value,
                line = tok.line,
                column = tok.column,
            })
        end
    end

    if #stack > 1 then
        for i = 2, #stack do
            addDiagnostic(diagnostics, "warning", "Unclosed tag <" .. stack[i].name .. ">", stack[i].line, stack[i].column)
        end
    end

    return root, diagnostics, tokens
end

--------------------------------------------------------------------------------
-- CSS Parser (basic)
--------------------------------------------------------------------------------

local CssParser = {}

function CssParser.tokenize(source)
    local tokens = {}
    local lex = makeLexer(source)
    while not lex.eof() do
        lex.skipWhitespace()
        if lex.eof() then break end
        local c = lex.peek()
        local startLine, startCol = lex.line(), lex.col()

        if c == "/" and lex.peek(1) == "*" then
            lex.advance() lex.advance()
            local buf = ""
            while not lex.eof() and not (lex.peek() == "*" and lex.peek(1) == "/") do
                buf = buf .. lex.advance()
            end
            if lex.peek() == "*" then lex.advance() end
            if lex.peek() == "/" then lex.advance() end
            table.insert(tokens, { type = "comment", value = buf, line = startLine, column = startCol })
        elseif c == "{" then
            lex.advance()
            table.insert(tokens, { type = "lbrace", line = startLine, column = startCol })
        elseif c == "}" then
            lex.advance()
            table.insert(tokens, { type = "rbrace", line = startLine, column = startCol })
        elseif c == ":" then
            lex.advance()
            table.insert(tokens, { type = "colon", line = startLine, column = startCol })
        elseif c == ";" then
            lex.advance()
            table.insert(tokens, { type = "semicolon", line = startLine, column = startCol })
        elseif c == "," then
            lex.advance()
            table.insert(tokens, { type = "comma", line = startLine, column = startCol })
        elseif c == '"' or c == "'" then
            local q = lex.advance()
            local buf = ""
            while not lex.eof() and lex.peek() ~= q do
                if lex.peek() == "\\" then
                    buf = buf .. lex.advance()
                    if not lex.eof() then buf = buf .. lex.advance() end
                else
                    buf = buf .. lex.advance()
                end
            end
            if lex.peek() == q then lex.advance() end
            table.insert(tokens, { type = "string", value = buf, line = startLine, column = startCol })
        else
            local buf = ""
            while not lex.eof() do
                local ch = lex.peek()
                if ch == "{" or ch == "}" or ch == ":" or ch == ";" or ch == "," or ch == '"' or ch == "'"
                    or ch == " " or ch == "\t" or ch == "\n" or ch == "\r"
                    or (ch == "/" and lex.peek(1) == "*") then
                    break
                end
                buf = buf .. lex.advance()
            end
            if buf ~= "" then
                table.insert(tokens, { type = "ident", value = buf, line = startLine, column = startCol })
            else
                -- skip unknown char
                lex.advance()
            end
        end
    end
    return tokens
end

function CssParser.parse(source)
    local tokens = CssParser.tokenize(source)
    local rules = {}
    local diagnostics = {}
    local i = 1

    local function peek() return tokens[i] end
    local function nextTok() local t = tokens[i]; i = i + 1; return t end

    while i <= #tokens do
        while peek() and peek().type == "comment" do nextTok() end
        if not peek() then break end

        -- selector list
        local selectors = {}
        local sel = ""
        while peek() and peek().type ~= "lbrace" do
            local t = nextTok()
            if t.type == "ident" or t.type == "string" then
                if sel ~= "" then sel = sel .. " " end
                sel = sel .. t.value
            elseif t.type == "comma" then
                if sel ~= "" then table.insert(selectors, sel); sel = "" end
            elseif t.type == "comment" then
                -- skip
            else
                -- include punctuation-like idents already handled
            end
        end
        if sel ~= "" then table.insert(selectors, sel) end

        if not peek() or peek().type ~= "lbrace" then
            if peek() then
                addDiagnostic(diagnostics, "error", "Expected '{' after selector", peek().line, peek().column)
                nextTok()
            end
            break
        end
        nextTok() -- {

        local declarations = {}
        while peek() and peek().type ~= "rbrace" do
            while peek() and peek().type == "comment" do nextTok() end
            if not peek() or peek().type == "rbrace" then break end

            local propTok = nextTok()
            if propTok.type ~= "ident" then
                addDiagnostic(diagnostics, "error", "Expected property name", propTok.line, propTok.column)
                break
            end
            local prop = propTok.value

            while peek() and peek().type == "comment" do nextTok() end
            if not peek() or peek().type ~= "colon" then
                addDiagnostic(diagnostics, "error", "Expected ':' after property", propTok.line, propTok.column)
                break
            end
            nextTok() -- :

            local valueParts = {}
            while peek() and peek().type ~= "semicolon" and peek().type ~= "rbrace" do
                local vt = nextTok()
                if vt.type == "ident" or vt.type == "string" then
                    table.insert(valueParts, vt.value)
                elseif vt.type == "comment" then
                    -- skip
                end
            end
            local value = table.concat(valueParts, " ")
            table.insert(declarations, { property = prop, value = value, line = propTok.line, column = propTok.column })

            if peek() and peek().type == "semicolon" then nextTok() end
        end

        if peek() and peek().type == "rbrace" then nextTok() end

        table.insert(rules, {
            type = "rule",
            selectors = selectors,
            declarations = declarations,
        })
    end

    return { type = "stylesheet", rules = rules }, diagnostics, tokens
end

--------------------------------------------------------------------------------
-- JSON (via HttpService when available, else minimal)
--------------------------------------------------------------------------------

local Json = {}

function Json.parse(source)
    if game and game.GetService then
        local ok, hs = pcall(function() return game:GetService("HttpService") end)
        if ok and hs and isFunction(hs.JSONDecode) then
            local ok2, result = pcall(function() return hs:JSONDecode(source) end)
            if ok2 then
                return true, result
            else
                return false, tostring(result)
            end
        end
    end
    -- Extremely minimal fallback: only accept empty object/array
    local t = string.match(source, "^%s*(.-)%s*$")
    if t == "{}" then return true, {} end
    if t == "[]" then return true, {} end
    return false, "JSONDecode unavailable and source is not empty object/array (full JSON requires HttpService)"
end

function Json.serialize(value)
    if game and game.GetService then
        local ok, hs = pcall(function() return game:GetService("HttpService") end)
        if ok and hs and isFunction(hs.JSONEncode) then
            local ok2, result = pcall(function() return hs:JSONEncode(value) end)
            if ok2 then return true, result end
            return false, tostring(result)
        end
    end
    if value == nil then return true, "null" end
    if type(value) == "boolean" then return true, value and "true" or "false" end
    if type(value) == "number" then return true, tostring(value) end
    if type(value) == "string" then
        return true, '"' .. string.gsub(value, '"', '\\"') .. '"'
    end
    if type(value) == "table" then
        -- shallow array or object detection
        local isArray = true
        local n = 0
        for k, _ in pairs(value) do
            n = n + 1
            if type(k) ~= "number" then isArray = false break end
        end
        if isArray then
            local parts = {}
            for i = 1, n do
                local ok, s = Json.serialize(value[i])
                if not ok then return false, s end
                table.insert(parts, s)
            end
            return true, "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(value) do
                local ok1, ks = Json.serialize(tostring(k))
                local ok2, vs = Json.serialize(v)
                if not ok1 or not ok2 then return false, "serialize error" end
                table.insert(parts, ks .. ":" .. vs)
            end
            return true, "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return false, "Unsupported type for JSON serialize"
end

--------------------------------------------------------------------------------
-- JavaScript / TS / JSX / PHP stubs (no full parser)
--------------------------------------------------------------------------------

local function unavailableBackend(lang, stage)
    return makeResult({
        success = false,
        language = lang,
        stage = stage,
        error = {
            code = "BACKEND_UNAVAILABLE",
            message = "No " .. stage .. " backend available for language '" .. lang .. "' inside pure Luau. Use a remote backend or plugin.",
        },
        diagnostics = {
            { severity = "error", message = "BACKEND_UNAVAILABLE for " .. lang },
        },
    })
end

local function syntaxCheckJsLike(source, lang)
    -- Very lightweight structural checks only; NOT a real JS parser.
    local diagnostics = {}
    local warnings = {}
    local depth = 0
    local inStr = nil
    local line, col = 1, 1
    local i = 1
    local len = #source

    while i <= len do
        local c = string.sub(source, i, i)
        if inStr then
            if c == "\\" then
                i = i + 2
                col = col + 2
            elseif c == inStr then
                inStr = nil
                i = i + 1
                col = col + 1
            elseif c == "\n" then
                line = line + 1
                col = 1
                i = i + 1
            else
                i = i + 1
                col = col + 1
            end
        else
            if c == '"' or c == "'" or c == "`" then
                inStr = c
                i = i + 1
                col = col + 1
            elseif c == "/" and string.sub(source, i + 1, i + 1) == "/" then
                while i <= len and string.sub(source, i, i) ~= "\n" do i = i + 1 end
            elseif c == "/" and string.sub(source, i + 1, i + 1) == "*" then
                i = i + 2
                while i <= len and not (string.sub(source, i, i + 1) == "*/") do
                    if string.sub(source, i, i) == "\n" then line = line + 1; col = 1 else col = col + 1 end
                    i = i + 1
                end
                i = i + 2
            elseif c == "{" or c == "(" or c == "[" then
                depth = depth + 1
                i = i + 1
                col = col + 1
            elseif c == "}" or c == ")" or c == "]" then
                depth = depth - 1
                if depth < 0 then
                    addDiagnostic(diagnostics, "error", "Unmatched closing bracket", line, col)
                    depth = 0
                end
                i = i + 1
                col = col + 1
            elseif c == "\n" then
                line = line + 1
                col = 1
                i = i + 1
            else
                i = i + 1
                col = col + 1
            end
        end
    end
    if depth > 0 then
        addDiagnostic(diagnostics, "error", "Unclosed brackets (depth=" .. depth .. ")", line, col)
    end
    if inStr then
        addDiagnostic(diagnostics, "error", "Unterminated string literal", line, col)
    end

    local success = #diagnostics == 0
    return makeResult({
        success = success,
        language = lang,
        stage = "validate",
        output = success and source or nil,
        diagnostics = diagnostics,
        warnings = warnings,
        error = success and nil or { code = "SYNTAX_ERROR", message = "Basic structural validation failed" },
        metadata = { note = "Lightweight bracket/string check only; not a full " .. lang .. " parser" },
    })
end

--------------------------------------------------------------------------------
-- Plugin system
--------------------------------------------------------------------------------

local function validatePlugin(plugin)
    if not isTable(plugin) then
        return false, "Plugin must be a table"
    end
    if not isString(plugin.name) or plugin.name == "" then
        return false, "Plugin.name must be a non-empty string"
    end
    if not isString(plugin.version) then
        return false, "Plugin.version must be a string"
    end
    if not isTable(plugin.languages) then
        return false, "Plugin.languages must be a table (array of strings)"
    end
    if not isTable(plugin.capabilities) then
        return false, "Plugin.capabilities must be a table"
    end
    local caps = plugin.capabilities
    for _, key in ipairs({ "detect", "parse", "transform", "compile" }) do
        if caps[key] ~= nil and type(caps[key]) ~= "boolean" then
            return false, "capabilities." .. key .. " must be boolean"
        end
    end
    -- Require at least one handler matching declared capabilities
    if caps.parse and not isFunction(plugin.parse) then
        return false, "capabilities.parse=true requires plugin.parse function"
    end
    if caps.transform and not isFunction(plugin.transform) then
        return false, "capabilities.transform=true requires plugin.transform function"
    end
    if caps.compile and not isFunction(plugin.compile) then
        return false, "capabilities.compile=true requires plugin.compile function"
    end
    if caps.detect and not isFunction(plugin.detect) then
        -- detect is optional even if declared; built-in detector can be used
    end
    return true
end

function Luanium:RegisterPlugin(plugin)
    local ok, err = validatePlugin(plugin)
    if not ok then
        return false, err
    end
    if state.plugins[plugin.name] then
        return false, "Plugin already registered: " .. plugin.name
    end
    state.plugins[plugin.name] = plugin
    return true
end

local function findPluginForLanguage(lang, capability)
    for _, p in pairs(state.plugins) do
        local langs = p.languages or {}
        local hasLang = false
        for _, l in ipairs(langs) do
            if string.lower(l) == string.lower(lang) then
                hasLang = true
                break
            end
        end
        if hasLang and p.capabilities and p.capabilities[capability] then
            return p
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Core pipeline stages
--------------------------------------------------------------------------------

local function stageDetect(config)
    local source = config.source or ""
    local lang = detectLanguage(source, config.language)
    -- Allow plugin override
    for _, p in pairs(state.plugins) do
        if p.capabilities and p.capabilities.detect and isFunction(p.detect) then
            local ok, detected = pcall(p.detect, source, config)
            if ok and isString(detected) and detected ~= "" then
                lang = detected
                break
            end
        end
    end
    return makeResult({
        success = true,
        language = lang,
        stage = "detect",
        output = lang,
        metadata = { sourceLength = #source },
    })
end

local function stageParse(config, language)
    language = language or config.language or "unknown"
    local source = config.source or ""

    if #source > DEFAULTS.maxSourceBytes then
        return makeResult({
            success = false,
            language = language,
            stage = "parse",
            error = { code = "SOURCE_TOO_LARGE", message = "Source exceeds maxSourceBytes" },
        })
    end

    -- Plugin first
    local plugin = findPluginForLanguage(language, "parse")
    if plugin and isFunction(plugin.parse) then
        local ok, result = pcall(plugin.parse, source, config)
        if ok and isTable(result) then
            result.stage = result.stage or "parse"
            result.language = result.language or language
            return result
        end
        return makeResult({
            success = false,
            language = language,
            stage = "parse",
            error = { code = "PLUGIN_ERROR", message = tostring(result) },
        })
    end

    if language == "html" then
        local ast, diagnostics = HtmlParser.parse(source)
        return makeResult({
            success = #diagnostics == 0 or true, -- warnings ok
            language = "html",
            stage = "parse",
            output = ast,
            diagnostics = diagnostics,
            metadata = { nodeCount = (function()
                local n = 0
                local function walk(node)
                    n = n + 1
                    if node.children then for _, c in ipairs(node.children) do walk(c) end end
                end
                walk(ast)
                return n
            end)() },
        })
    elseif language == "css" then
        local ast, diagnostics = CssParser.parse(source)
        return makeResult({
            success = true,
            language = "css",
            stage = "parse",
            output = ast,
            diagnostics = diagnostics,
            metadata = { ruleCount = #(ast.rules or {}) },
        })
    elseif language == "json" then
        local ok, data = Json.parse(source)
        if ok then
            return makeResult({
                success = true,
                language = "json",
                stage = "parse",
                output = data,
            })
        else
            return makeResult({
                success = false,
                language = "json",
                stage = "parse",
                error = { code = "PARSE_ERROR", message = data },
                diagnostics = { { severity = "error", message = data } },
            })
        end
    elseif language == "javascript" or language == "typescript" or language == "jsx" or language == "tsx" then
        -- No full parser; return structural validation only
        local v = syntaxCheckJsLike(source, language)
        v.stage = "parse"
        v.metadata = v.metadata or {}
        v.metadata.note = "No full " .. language .. " parser in pure Luau; structural check only"
        if not v.success then
            v.error = { code = "PARSER_UNAVAILABLE", message = "Full " .. language .. " parser unavailable" }
        else
            -- Still mark that full AST is unavailable
            v.output = { type = "opaque", language = language, length = #source }
            v.warnings = addDiagnostic(v.warnings or {}, "warning", "Returning opaque AST; full parse requires plugin or remote backend")
        end
        return v
    elseif language == "php" then
        return unavailableBackend("php", "parse")
    elseif language == "markdown" or language == "yaml" or language == "xml" then
        return makeResult({
            success = false,
            language = language,
            stage = "parse",
            error = { code = "PARSER_UNAVAILABLE", message = "Parser for '" .. language .. "' is not built-in; register a plugin" },
        })
    else
        return makeResult({
            success = false,
            language = language,
            stage = "parse",
            error = { code = "UNSUPPORTED_LANGUAGE", message = "Language '" .. tostring(language) .. "' is not supported" },
        })
    end
end

local function stageTransform(config, language, parseResult)
    language = language or (parseResult and parseResult.language) or "unknown"
    local target = config.target or "ast"

    local plugin = findPluginForLanguage(language, "transform")
    if plugin and isFunction(plugin.transform) then
        local ok, result = pcall(plugin.transform, parseResult and parseResult.output, config)
        if ok and isTable(result) then
            result.stage = result.stage or "transform"
            result.language = result.language or language
            return result
        end
        return makeResult({
            success = false,
            language = language,
            stage = "transform",
            error = { code = "PLUGIN_ERROR", message = tostring(result) },
        })
    end

    if target == "source" then
        return makeResult({
            success = true,
            language = language,
            stage = "transform",
            output = config.source,
            metadata = { target = "source" },
        })
    elseif target == "ast" then
        if parseResult and parseResult.success then
            return makeResult({
                success = true,
                language = language,
                stage = "transform",
                output = parseResult.output,
                diagnostics = parseResult.diagnostics,
                metadata = { target = "ast" },
            })
        else
            return makeResult({
                success = false,
                language = language,
                stage = "transform",
                error = { code = "NO_AST", message = "Parse did not produce AST" },
            })
        end
    elseif target == "ir" then
        -- Minimal IR: just wrap AST
        if parseResult and parseResult.success then
            return makeResult({
                success = true,
                language = language,
                stage = "transform",
                output = { type = "ir", language = language, ast = parseResult.output },
                metadata = { target = "ir" },
            })
        end
        return makeResult({
            success = false,
            language = language,
            stage = "transform",
            error = { code = "NO_AST", message = "Cannot build IR without AST" },
        })
    elseif target == "luau" then
        return makeResult({
            success = false,
            language = language,
            stage = "transform",
            error = {
                code = "BACKEND_UNAVAILABLE",
                message = "No built-in " .. language .. " → Luau transformer. Provide a plugin or remote backend.",
            },
        })
    elseif target == "remote" then
        if not config.remoteUrl then
            return makeResult({
                success = false,
                language = language,
                stage = "transform",
                error = { code = "MISSING_REMOTE_URL", message = "config.remoteUrl required for target=remote" },
            })
        end
        -- User-configured remote only; we POST source and expect response body as output
        local body = config.source or ""
        local headers = config.remoteHeaders or { ["Content-Type"] = "text/plain" }
        local httpRes = HTTP:Post(config.remoteUrl, body, { headers = headers, timeout = config.timeout })
        if not httpRes.success then
            return makeResult({
                success = false,
                language = language,
                stage = "transform",
                error = httpRes.error or { code = "REMOTE_ERROR", message = "Remote backend failed" },
                metadata = httpRes.metadata,
            })
        end
        return makeResult({
            success = true,
            language = language,
            stage = "transform",
            output = httpRes.output,
            metadata = { target = "remote", statusCode = httpRes.metadata and httpRes.metadata.statusCode },
        })
    else
        return makeResult({
            success = false,
            language = language,
            stage = "transform",
            error = { code = "UNKNOWN_TARGET", message = "Unknown target: " .. tostring(target) },
        })
    end
end

local function stageCompile(config)
    local source = config.source
    if not isString(source) then
        return makeResult({
            success = false,
            stage = "compile",
            error = { code = "INVALID_SOURCE", message = "config.source must be a string" },
        })
    end
    if #source > DEFAULTS.maxSourceBytes then
        return makeResult({
            success = false,
            stage = "compile",
            error = { code = "SOURCE_TOO_LARGE", message = "Source exceeds maxSourceBytes (" .. DEFAULTS.maxSourceBytes .. ")" },
        })
    end

    -- Detect
    local det = stageDetect(config)
    local language = det.language or "unknown"

    -- Plugin compile path
    local plugin = findPluginForLanguage(language, "compile")
    if plugin and isFunction(plugin.compile) then
        local ok, result = pcall(plugin.compile, source, config)
        if ok and isTable(result) then
            result.stage = result.stage or "compile"
            result.language = result.language or language
            return result
        end
        return makeResult({
            success = false,
            language = language,
            stage = "compile",
            error = { code = "PLUGIN_ERROR", message = tostring(result) },
        })
    end

    -- Parse
    local parsed = stageParse(config, language)
    if not parsed.success and language ~= "javascript" and language ~= "typescript" and language ~= "jsx" and language ~= "tsx" then
        -- For JS-like we still allow transform to report opaque
        if language ~= "html" and language ~= "css" and language ~= "json" then
            return parsed
        end
    end

    -- Transform
    local transformed = stageTransform(config, language, parsed)
    transformed.stage = "compile"
    transformed.metadata = transformed.metadata or {}
    transformed.metadata.detectedLanguage = language
    transformed.metadata.parseSuccess = parsed.success
    if parsed.diagnostics and #parsed.diagnostics > 0 then
        transformed.diagnostics = transformed.diagnostics or {}
        for _, d in ipairs(parsed.diagnostics) do
            table.insert(transformed.diagnostics, d)
        end
    end
    return transformed
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Luanium:GetVersion()
    return self._VERSION
end

function Luanium:GetLanguages()
    local builtIn = {
        {
            id = "html",
            name = "HTML",
            capabilities = { detect = true, parse = true, transform = true, compile = true },
            notes = "Basic tokenizer + tree builder (tags, attributes, text, comments). Not a browser-grade parser.",
        },
        {
            id = "css",
            name = "CSS",
            capabilities = { detect = true, parse = true, transform = true, compile = true },
            notes = "Basic rule/selector/declaration parser. No full cascade or at-rules support.",
        },
        {
            id = "json",
            name = "JSON",
            capabilities = { detect = true, parse = true, transform = true, compile = true },
            notes = "Uses HttpService:JSONDecode/Encode when available.",
        },
        {
            id = "javascript",
            name = "JavaScript",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Structural bracket/string check only. Full parse requires plugin or remote backend.",
        },
        {
            id = "typescript",
            name = "TypeScript",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Detection heuristic + structural check. No TS compiler.",
        },
        {
            id = "jsx",
            name = "JSX",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Detection heuristic only.",
        },
        {
            id = "tsx",
            name = "TSX",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Detection heuristic only.",
        },
        {
            id = "php",
            name = "PHP",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Source recognition only. No PHP runtime in Luau.",
        },
        {
            id = "markdown",
            name = "Markdown",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Extend via plugin.",
        },
        {
            id = "yaml",
            name = "YAML",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Extend via plugin.",
        },
        {
            id = "xml",
            name = "XML",
            capabilities = { detect = true, parse = false, transform = false, compile = false },
            notes = "Extend via plugin.",
        },
    }

    -- Merge plugin languages
    for _, p in pairs(state.plugins) do
        for _, lang in ipairs(p.languages or {}) do
            local found = false
            for _, b in ipairs(builtIn) do
                if b.id == string.lower(lang) then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(builtIn, {
                    id = string.lower(lang),
                    name = lang,
                    capabilities = p.capabilities or {},
                    notes = "Provided by plugin: " .. p.name,
                    plugin = p.name,
                })
            end
        end
    end
    return builtIn
end

function Luanium:GetCapabilities()
    if state.capabilities then
        return deepCopy(state.capabilities)
    end
    local httpCaps = HTTP:GetCapabilities()
    local caps = {
        version = self._VERSION,
        http = httpCaps,
        languages = self:GetLanguages(),
        targets = { "source", "ast", "ir", "luau", "remote" },
        features = {
            cache = DEFAULTS.allowCache,
            plugins = true,
            customTransport = true,
            maxSourceBytes = DEFAULTS.maxSourceBytes,
            maxResponseBytes = DEFAULTS.maxResponseBytes,
            maxRequestsPerSession = DEFAULTS.maxRequestsPerSession,
        },
        limitations = {
            "No automatic execution of fetched or compiled source",
            "No loadstring on HTML/JS/PHP/remote content",
            "JavaScript/TypeScript/JSX/TSX/PHP lack full parsers in pure Luau",
            "POST is never auto-retried",
            "Does not bypass CAPTCHA, auth walls or site protections",
            "Executor HTTP APIs vary; capability detection is best-effort",
        },
    }
    state.capabilities = caps
    return deepCopy(caps)
end

function Luanium:ClearCache()
    clearCache()
    return true
end

function Luanium:Fetch(url, options, callback)
    if isFunction(options) and callback == nil then
        callback = options
        options = {}
    end
    options = options or {}
    if not DEFAULTS.allowRemoteFetch then
        local res = makeResult({
            success = false,
            stage = "fetch",
            error = { code = "FETCH_DISABLED", message = "Remote fetch is disabled" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
    local httpRes = HTTP:Get(url, options)
    -- Re-tag stage
    httpRes.stage = "fetch"
    if isFunction(callback) then callback(httpRes) end
    return httpRes
end

function Luanium:Parse(config, callback)
    if not isTable(config) then
        local res = makeResult({
            success = false,
            stage = "parse",
            error = { code = "INVALID_CONFIG", message = "config must be a table" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
    local language = config.language
    if not language or language == "auto" then
        local det = stageDetect(config)
        language = det.language
    end
    local res = stageParse(config, language)
    if isFunction(callback) then callback(res) end
    return res
end

function Luanium:Transform(config, callback)
    if not isTable(config) then
        local res = makeResult({
            success = false,
            stage = "transform",
            error = { code = "INVALID_CONFIG", message = "config must be a table" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
    local language = config.language
    if not language or language == "auto" then
        local det = stageDetect(config)
        language = det.language
    end
    local parsed = stageParse(config, language)
    local res = stageTransform(config, language, parsed)
    if isFunction(callback) then callback(res) end
    return res
end

function Luanium:Validate(config, callback)
    if not isTable(config) then
        local res = makeResult({
            success = false,
            stage = "validate",
            error = { code = "INVALID_CONFIG", message = "config must be a table" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
    local language = config.language
    if not language or language == "auto" then
        local det = stageDetect(config)
        language = det.language
    end

    if language == "html" or language == "css" or language == "json" then
        local parsed = stageParse(config, language)
        local res = makeResult({
            success = parsed.success,
            language = language,
            stage = "validate",
            output = parsed.success and true or false,
            diagnostics = parsed.diagnostics,
            warnings = parsed.warnings,
            error = parsed.error,
            metadata = parsed.metadata,
        })
        if isFunction(callback) then callback(res) end
        return res
    elseif language == "javascript" or language == "typescript" or language == "jsx" or language == "tsx" then
        local res = syntaxCheckJsLike(config.source or "", language)
        if isFunction(callback) then callback(res) end
        return res
    else
        local res = makeResult({
            success = false,
            language = language,
            stage = "validate",
            error = { code = "VALIDATOR_UNAVAILABLE", message = "No validator for language '" .. tostring(language) .. "'" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
end

function Luanium:Compile(config, callback)
    if not isTable(config) then
        local res = makeResult({
            success = false,
            stage = "compile",
            error = { code = "INVALID_CONFIG", message = "config must be a table with .source string" },
        })
        if isFunction(callback) then callback(res) end
        return res
    end
    local res = stageCompile(config)
    if isFunction(callback) then callback(res) end
    return res
end

--------------------------------------------------------------------------------
-- Example usage (commented; not executed)
--------------------------------------------------------------------------------
--[[
    local Luanium = loadstring(game:HttpGet("https://raw.githubusercontent.com/OWNER/Luanium/main/luanium.luau"))()

    -- Version
    print(Luanium:GetVersion())

    -- HTTP GET
    Luanium.HTTP:Get("https://example.com", function(res)
        if res.success then
            print("Body length:", #res.output)
        else
            warn(res.error.message)
        end
    end)

    -- Compile HTML to AST
    Luanium:Compile({
        source = "<html><body><h1>Hello</h1></body></html>",
        language = "html",
        target = "ast",
    }, function(result)
        if result.success then
            print("AST root type:", result.output.type)
        else
            warn(result.error.code, result.error.message)
        end
    end)

    -- Register a plugin
    Luanium:RegisterPlugin({
        name = "Example",
        version = "1.0.0",
        languages = { "example" },
        capabilities = { detect = true, parse = true, transform = false, compile = false },
        detect = function(source) return "example" end,
        parse = function(source, config)
            return {
                success = true,
                language = "example",
                stage = "parse",
                output = { type = "example-ast", length = #source },
                diagnostics = {},
                warnings = {},
                error = nil,
                metadata = {},
            }
        end,
    })
]]

--------------------------------------------------------------------------------
-- Return public table
--------------------------------------------------------------------------------

return Luanium
