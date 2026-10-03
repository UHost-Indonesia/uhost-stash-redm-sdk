-- uhsdk server: talks to the UHost R2 game API (/api/v3/file).
-- The API key lives only here (convar "uhost_api_key"); clients upload through
-- one-time presigned URLs and never see it.

local FILE_TYPES = { image = true, video = true, audio = true }
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local pendingCaptures = {}
local lastClientRequest = {}
local captureCounter = 0

local function debugLog(...)
    if Config.Debug then print('^5[uhsdk]^7', ...) end
end

local function fail(message)
    error('uhsdk: ' .. message, 0)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function apiUrl()
    return (GetConvar('uhost_api_url', 'https://r2.uhost.id'):gsub('/+$', ''))
end

local function urlEncode(value)
    return (tostring(value):gsub('[^%w%-_%.~]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

-- Encode a path but keep its slashes ("screenshots/a b.png" -> "screenshots/a%20b.png")
local function encodePath(value)
    return (tostring(value):gsub('[^%w%-_%.~/]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

local function buildQuery(params)
    local parts = {}
    for key, value in pairs(params or {}) do
        if value ~= nil and value ~= '' then
            parts[#parts + 1] = urlEncode(key) .. '=' .. urlEncode(value)
        end
    end
    return table.concat(parts, '&')
end

local function base64Encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
            .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or '=')
            .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
    end
    return table.concat(out)
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    -- Functions passed across resources arrive as function-reference tables
    return type(value) == 'table' and rawget(value, '__cfx_functionReference') ~= nil
end

-- json.encode({}) yields "[]", which the API rejects as metadata
local function encodeMetadata(metadata)
    if type(metadata) ~= 'table' or next(metadata) == nil then return nil end
    return json.encode(metadata)
end

local function decodeJson(text)
    if type(text) ~= 'string' or text == '' then return nil end
    local ok, data = pcall(json.decode, text)
    if ok and type(data) == 'table' then return data end
    -- errorData may be prefixed (e.g. "HTTP 400: {...}")
    local body = text:match('{.*}')
    if body then
        ok, data = pcall(json.decode, body)
        if ok and type(data) == 'table' then return data end
    end
    return nil
end

local function httpRequest(method, path, query, body, headers)
    local key = GetConvar('uhost_api_key', '')
    if key == '' then fail('convar "uhost_api_key" is not set in server.cfg') end

    query = query or {}
    local bucket = GetConvar('uhost_bucket', '')
    if bucket ~= '' and query.bucket == nil then query.bucket = bucket end

    local qs = buildQuery(query)
    local url = apiUrl() .. path .. (qs ~= '' and ('?' .. qs) or '')
    headers = headers or {}
    headers['Authorization'] = key

    debugLog(method, url)
    local p = promise.new()
    PerformHttpRequest(url, function(status, text, _, errorData)
        local data = decodeJson(text) or decodeJson(errorData)
        if status >= 200 and status < 300 then
            p:resolve(data or {})
        else
            local message = (data and data.error) or errorData or ('HTTP ' .. tostring(status))
            p:reject(('uhsdk: %s %s failed (%s): %s'):format(method, path, tostring(status), tostring(message)))
        end
    end, method, body or '', headers)
    return Citizen.Await(p)
end

-- Upload result: res.url / res.id, with full details in res.data
local function toResult(file)
    file = file or {}
    return { status = 'ok', id = file.id, url = file.url, data = file }
end

local function playerInfo(src)
    local info = { playerSource = src, playerName = GetPlayerName(src) }
    local identifiers = {}
    for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
        local kind = identifier:match('^([%w_]+):')
        if kind and not Config.ExcludedIdentifiers[kind] then identifiers[kind] = identifier end
    end
    info.identifiers = identifiers
    return info
end

-- Fields from `trusted` win over `base`
local function mergeTables(base, trusted)
    local out = {}
    if type(base) == 'table' then for k, v in pairs(base) do out[k] = v end end
    if type(trusted) == 'table' then for k, v in pairs(trusted) do out[k] = v end end
    return out
end

local function withPlayerInfo(src, metadata)
    if not Config.AppendPlayerInfo or not src then return metadata end
    return mergeTables(metadata, playerInfo(src))
end

local function screenshotBasicReady()
    return GetResourceState('screenshot-basic') == 'started'
end

-- ---------------------------------------------------------------------------
-- Core API
-- ---------------------------------------------------------------------------

local function createPresigned(fileType, options)
    options = options or {}
    if fileType ~= nil and not FILE_TYPES[fileType] then fail('fileType must be "image", "video" or "audio"') end
    local resp = httpRequest('GET', '/api/v3/file/presigned-url', {
        fileType = fileType,
        path = options.path or (fileType and Config.Folders[fileType]) or nil,
        filename = options.filename,
        metadata = encodeMetadata(options.metadata),
        expiresAt = options.expiresIn and (os.time() + math.floor(options.expiresIn)) or nil,
    })
    if not resp.data or not resp.data.presignedUrl then fail('API did not return a presigned URL') end
    return resp.data
end

local function requestPresignedUrl(fileType, options)
    return createPresigned(fileType, options).presignedUrl
end

-- Upload from the server: data may be a data URI, base64 or raw bytes
local function uploadImage(data, options)
    options = options or {}
    if type(data) ~= 'string' or data == '' then fail('upload data is empty') end

    local payload = data
    if data:sub(1, 5) ~= 'data:' and (#data % 4 ~= 0 or data:find('[^%w%+/=]')) then
        payload = base64Encode(data)
    end

    local resp = httpRequest('POST', '/api/v3/file/base64', nil, json.encode({
        base64 = payload,
        filename = options.fileName or options.filename,
        path = options.path,
        metadata = encodeMetadata(options.metadata),
    }), { ['Content-Type'] = 'application/json' })
    return toResult(resp.data)
end

-- Ask a player's client for a screenshot. The client uploads straight to the
-- API with a one-time URL; the result is then confirmed server-side, so a
-- modified client cannot report a fake URL.
local function takeServerImage(playerSource, metadata, options, timeout)
    local src = tonumber(playerSource)
    if not src or not GetPlayerName(src) then fail(('player %s not found'):format(tostring(playerSource))) end
    if not screenshotBasicReady() then fail('resource "screenshot-basic" is not started') end
    options = options or {}

    local presigned = createPresigned('image', {
        path = options.path,
        filename = options.filename,
        metadata = withPlayerInfo(src, metadata),
    })

    captureCounter = captureCounter + 1
    local requestId = captureCounter
    local p = promise.new()
    pendingCaptures[requestId] = { source = src, promise = p }

    TriggerClientEvent('uhsdk:capture', src, requestId, presigned.presignedUrl, {
        encoding = options.encoding,
        quality = options.quality,
    })

    SetTimeout(timeout or Config.Screenshot.timeoutMs, function()
        if pendingCaptures[requestId] then
            pendingCaptures[requestId] = nil
            p:reject('uhsdk: screenshot request timed out')
        end
    end)

    Citizen.Await(p)

    local status = httpRequest('GET', '/api/v3/file/presigned-url/' .. presigned.token)
    local file = status.data and status.data.file
    if not file then fail('client did not upload the screenshot') end
    return toResult(file)
end

local function getFile(id)
    local resp = httpRequest('GET', '/api/v3/file/' .. encodePath(id))
    return resp.data
end

local function listFiles(query)
    query = query or {}
    local resp = httpRequest('GET', '/api/v3/file', {
        type = query.type,
        path = query.path,
        page = query.page,
        limit = query.limit,
    })
    return { data = resp.data or {}, pagination = resp.pagination }
end

local function deleteFile(id)
    httpRequest('DELETE', '/api/v3/file/' .. encodePath(id))
    return true
end

-- ---------------------------------------------------------------------------
-- Exports: blocking in Lua (yields the calling thread), a Promise in JS.
-- Passing a function as the last argument switches to callback(result, err).
-- ---------------------------------------------------------------------------

local function export(name, fn)
    exports(name, function(...)
        local args = table.pack(...)
        local cb = args.n > 0 and isCallable(args[args.n]) and args[args.n] or nil
        if not cb then return fn(...) end

        args[args.n] = nil
        CreateThread(function()
            local ok, result = pcall(fn, table.unpack(args, 1, args.n - 1))
            if ok then cb(result, nil) else cb(nil, tostring(result)) end
        end)
    end)
end

export('takeServerImage', takeServerImage)
export('uploadImage', uploadImage)
export('requestPresignedUrl', requestPresignedUrl)
-- Extras
export('uploadFile', uploadImage)
export('getFile', getFile)
export('listFiles', listFiles)
export('deleteFile', deleteFile)

-- ---------------------------------------------------------------------------
-- Client bridge
-- ---------------------------------------------------------------------------

RegisterNetEvent('uhsdk:captureDone', function(requestId, err)
    local src = source
    local entry = pendingCaptures[requestId]
    -- Only the player that was asked may answer
    if not entry or entry.source ~= src then return end
    pendingCaptures[requestId] = nil
    if err then
        entry.promise:reject('uhsdk: ' .. tostring(err):sub(1, 200))
    else
        entry.promise:resolve(true)
    end
end)

local clientActions = {
    takeImage = function(src, payload)
        if not Config.AllowClientScreenshots then fail('client screenshots are disabled') end
        return { url = requestPresignedUrl('image', { metadata = withPlayerInfo(src, payload.metadata) }) }
    end,
    presign = function(src, payload)
        if not Config.AllowClientPresignedUrls then fail('client presigned URLs are disabled') end
        local fileType = payload.fileType
        if not FILE_TYPES[fileType] then fail('fileType must be "image", "video" or "audio"') end
        -- Clients cannot pick folders or file names: uploads always land in
        -- Config.Folders with a generated unique name.
        return { url = requestPresignedUrl(fileType, { metadata = withPlayerInfo(src, payload.metadata) }) }
    end,
}

RegisterNetEvent('uhsdk:rpc', function(requestId, action, payload)
    local src = source
    CreateThread(function()
        local now = GetGameTimer()
        local handler = clientActions[action]
        local ok, result
        if not handler then
            ok, result = false, 'uhsdk: unknown action'
        elseif lastClientRequest[src] and now - lastClientRequest[src] < Config.ClientCooldownMs then
            ok, result = false, 'uhsdk: too many requests, try again shortly'
        else
            lastClientRequest[src] = now
            ok, result = pcall(handler, src, type(payload) == 'table' and payload or {})
        end
        if not ok then debugLog(('client %d %s failed: %s'):format(src, tostring(action), tostring(result))) end
        TriggerClientEvent('uhsdk:rpc:result', src, requestId, ok, ok and result or tostring(result))
    end)
end)

AddEventHandler('playerDropped', function()
    lastClientRequest[source] = nil
end)

CreateThread(function()
    if GetConvar('uhost_api_key', '') == '' then
        print('^3[uhsdk] Warning: set "uhost_api_key" in server.cfg (set uhost_api_key "r2u_...")^7')
    end
    if not screenshotBasicReady() then
        print('^3[uhsdk] screenshot-basic is not running: takeImage/takeServerImage will not work^7')
    end
end)
