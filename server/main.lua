-- UHost Stash SDK (server): talks to the UHost Stash game API (/api/v3/file
-- for uploads, /api/v3/logs for logs).
-- The API key lives only here (convar "uhost_api_key"); clients upload through
-- one-time presigned URLs and never see it.

local RESOURCE = GetCurrentResourceName()
local FILE_TYPES = { image = true, video = true, audio = true }
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local pendingCaptures = {}
local lastClientRequest = {}
local captureCounter = 0

local function debugLog(...)
    if Config.Debug then print('^5[' .. RESOURCE .. ']^7', ...) end
end

local function fail(message)
    error(RESOURCE .. ': ' .. message, 0)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function apiUrl()
    return (GetConvar('uhost_api_url', 'https://stash.uhost.id'):gsub('/+$', ''))
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

local function requestUrl(path, query)
    query = query or {}
    local bucket = GetConvar('uhost_bucket', '')
    if bucket ~= '' and query.bucket == nil then query.bucket = bucket end

    local qs = buildQuery(query)
    return apiUrl() .. path .. (qs ~= '' and ('?' .. qs) or '')
end

local function httpRequest(method, path, query, body, headers)
    local key = GetConvar('uhost_api_key', '')
    if key == '' then fail('convar "uhost_api_key" is not set in server.cfg') end

    local url = requestUrl(path, query)
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
            p:reject((RESOURCE .. ': %s %s failed (%s): %s'):format(method, path, tostring(status), tostring(message)))
        end
    end, method, body or '', headers)
    return Citizen.Await(p)
end

-- Upload result: res.url / res.id, with full details in res.data
local function toResult(file)
    file = file or {}
    return { status = 'ok', id = file.id, url = file.url, data = file }
end

-- { license = 'license:...', discord = 'discord:...' } without excluded kinds
local function filterIdentifiers(list)
    local identifiers = {}
    for _, identifier in ipairs(list or {}) do
        local kind = type(identifier) == 'string' and identifier:match('^([%w_]+):')
        if kind and not Config.ExcludedIdentifiers[kind] then identifiers[kind] = identifier end
    end
    return identifiers
end

local function playerInfo(src)
    return {
        playerSource = src,
        playerName = GetPlayerName(src),
        identifiers = filterIdentifiers(GetPlayerIdentifiers(src)),
    }
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

    TriggerClientEvent(RESOURCE .. ':capture', src, requestId, presigned.presignedUrl, {
        encoding = options.encoding,
        quality = options.quality,
    })

    SetTimeout(timeout or Config.Screenshot.timeoutMs, function()
        if pendingCaptures[requestId] then
            pendingCaptures[requestId] = nil
            p:reject(RESOURCE .. ': screenshot request timed out')
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
-- Logs (/api/v3/logs). log() only queues; a background thread sends the
-- queue in batches. Network errors, rate limits and server errors are
-- retried; a batch the API rejects (bad input, invalid key) is dropped.
-- ---------------------------------------------------------------------------

local LOG_LEVELS = { debug = 'debug', info = 'info', warn = 'warn', warning = 'warn', error = 'error' }
local logQueue = {}
local logSending = false
local droppedLogs = 0

local function log(dataset, level, message, metadata)
    if type(dataset) ~= 'string' or dataset == '' then fail('log dataset must be a non-empty string') end
    local lvl = LOG_LEVELS[tostring(level or 'info'):lower()]
    if not lvl then fail('log level must be "debug", "info", "warn" or "error"') end
    if message == nil or message == '' then fail('log message is required') end

    if #logQueue >= Config.Logs.maxQueue then
        table.remove(logQueue, 1)
        droppedLogs = droppedLogs + 1
    end
    logQueue[#logQueue + 1] = {
        dataset = dataset,
        level = lvl,
        message = tostring(message),
        metadata = (type(metadata) == 'table' and next(metadata) ~= nil) and metadata or nil,
        -- The resource that called the export (nil for this resource's own logs)
        resource = GetInvokingResource() or RESOURCE,
        timestamp = os.time(),
    }
    return true
end

-- Sends one batch; true when it was accepted
local function sendLogBatch()
    local key = GetConvar('uhost_api_key', '')
    if logSending or #logQueue == 0 or key == '' then return false end
    logSending = true

    local count = math.min(#logQueue, Config.Logs.batchSize)
    local batch = table.move(logQueue, 1, count, 1, {})
    local p = promise.new()
    PerformHttpRequest(requestUrl('/api/v3/logs'), function(status, _, _, errorData)
        p:resolve({ status = status, error = errorData })
    end, 'POST', json.encode({ logs = batch }), { ['Content-Type'] = 'application/json', ['Authorization'] = key })
    local res = Citizen.Await(p)
    logSending = false

    local ok = res.status >= 200 and res.status < 300
    if not ok and (res.status == 0 or res.status == 429 or res.status >= 500) then
        debugLog(('log upload failed (%s), retrying later'):format(tostring(res.status)))
        return false
    end
    -- Logs queued while this request was running stay in the queue
    logQueue = table.move(logQueue, count + 1, #logQueue, 1, {})
    if not ok then
        print(('^3[%s] %d logs rejected (HTTP %s): %s^7'):format(RESOURCE, count, tostring(res.status), tostring(res.error):sub(1, 300)))
    end
    return ok
end

-- Sends everything queued now (blocks); false if something could not be sent
local function flushLogs()
    while #logQueue > 0 do
        if logSending then
            Wait(50)
        elseif not sendLogBatch() then
            return false
        end
    end
    return true
end

CreateThread(function()
    local lastSent = GetGameTimer()
    while true do
        Wait(250)
        local due = GetGameTimer() - lastSent >= Config.Logs.flushIntervalMs
        if #logQueue > 0 and (due or #logQueue >= Config.Logs.batchSize) then
            lastSent = GetGameTimer()
            local ok, err = pcall(sendLogBatch)
            if not ok then
                logSending = false
                debugLog('log upload error: ' .. tostring(err))
            end
        end
        if droppedLogs > 0 then
            print(('^3[%s] %d logs dropped: the queue was full (is the API reachable?)^7'):format(RESOURCE, droppedLogs))
            droppedLogs = 0
        end
    end
end)

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
-- Logs
export('log', log)
export('flushLogs', flushLogs)

-- ---------------------------------------------------------------------------
-- Client bridge
-- ---------------------------------------------------------------------------

RegisterNetEvent(RESOURCE .. ':captureDone', function(requestId, err)
    local src = source
    local entry = pendingCaptures[requestId]
    -- Only the player that was asked may answer
    if not entry or entry.source ~= src then return end
    pendingCaptures[requestId] = nil
    if err then
        entry.promise:reject(RESOURCE .. ': ' .. tostring(err):sub(1, 200))
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

RegisterNetEvent(RESOURCE .. ':rpc', function(requestId, action, payload)
    local src = source
    CreateThread(function()
        local now = GetGameTimer()
        local handler = clientActions[action]
        local ok, result
        if not handler then
            ok, result = false, RESOURCE .. ': unknown action'
        elseif lastClientRequest[src] and now - lastClientRequest[src] < Config.ClientCooldownMs then
            ok, result = false, RESOURCE .. ': too many requests, try again shortly'
        else
            lastClientRequest[src] = now
            ok, result = pcall(handler, src, type(payload) == 'table' and payload or {})
        end
        if not ok then debugLog(('client %d %s failed: %s'):format(src, tostring(action), tostring(result))) end
        TriggerClientEvent(RESOURCE .. ':rpc:result', src, requestId, ok, ok and result or tostring(result))
    end)
end)

AddEventHandler('playerDropped', function()
    lastClientRequest[source] = nil
end)

-- ---------------------------------------------------------------------------
-- Built-in event logs (Config.Logs)
-- ---------------------------------------------------------------------------

local function playerLabel(src)
    return GetPlayerName(src) or ('player ' .. tostring(src))
end

local function safeLog(dataset, level, message, metadata)
    local ok, err = pcall(log, dataset, level, message, metadata)
    if not ok then debugLog('log failed: ' .. tostring(err)) end
end

if Config.Logs.playerJoins then
    AddEventHandler('playerJoining', function()
        local src = source
        safeLog('joins', 'info', playerLabel(src) .. ' joined', playerInfo(src))
    end)

    AddEventHandler('playerDropped', function(reason)
        local src = source
        local info = playerInfo(src)
        info.reason = reason
        safeLog('joins', 'info', ('%s left (%s)'):format(playerLabel(src), tostring(reason or 'unknown')), info)
    end)
end

if Config.Logs.chat then
    AddEventHandler('chatMessage', function(src, author, text)
        if type(text) ~= 'string' or text == '' then return end
        local info = playerInfo(src)
        info.text = text
        safeLog('chat', 'info', ('%s: %s'):format(author or playerLabel(src), text), info)
    end)
end

-- txAdmin server events (txAdmin:events:*).
-- The event data goes into the metadata; identifiers are filtered like
-- everywhere else.
local function txTarget(data)
    if data.targetName then return data.targetName end
    local id = data.target or data.targetNetId
    if not id or id == -1 then return 'everyone' end
    return GetPlayerName(id) or ('player ' .. tostring(id))
end

local TXADMIN_EVENTS = {
    playerKicked = { 'warn', function(d) return ('%s was kicked by %s: %s'):format(txTarget(d), d.author or 'txAdmin', d.reason or '-') end },
    playerWarned = { 'warn', function(d) return ('%s was warned by %s: %s'):format(txTarget(d), d.author or 'txAdmin', d.reason or '-') end },
    playerBanned = { 'error', function(d)
        return ('%s was banned by %s (%s): %s'):format(txTarget(d), d.author or 'txAdmin', d.durationTranslated or 'permanent', d.reason or '-')
    end },
    actionRevoked = { 'info', function(d) return ('%s revoked %s %s'):format(d.revokedBy or 'an admin', d.actionType or 'action', d.actionId or '') end },
    playerHealed = { 'info', function(d) return txTarget(d) .. ' healed by txAdmin' end },
    playerDirectMessage = { 'info', function(d) return ('DM from %s to %s: %s'):format(d.author or 'txAdmin', txTarget(d), d.message or '') end },
    announcement = { 'info', function(d) return ('Announcement by %s: %s'):format(d.author or 'txAdmin', d.message or '') end },
    scheduledRestart = { 'warn', function(d) return 'Scheduled restart in ' .. tostring(d.translatedMessage or ((d.secondsRemaining or '?') .. ' seconds')) end },
    serverShuttingDown = { 'warn', function(d) return ('Server shutting down (%s)'):format(d.author or 'txAdmin') end },
}

if Config.Logs.txAdmin then
    for name, def in pairs(TXADMIN_EVENTS) do
        AddEventHandler('txAdmin:events:' .. name, function(data)
            data = type(data) == 'table' and data or {}
            local metadata = mergeTables(data, { event = name })
            if type(data.targetIds) == 'table' then metadata.targetIds = filterIdentifiers(data.targetIds) end
            local ok, message = pcall(def[2], data)
            safeLog('txadmin', def[1], ok and message or name, metadata)
        end)
    end
end

-- Best effort: send what is queued when the resource or server stops
AddEventHandler('onResourceStop', function(name)
    if name == RESOURCE and #logQueue > 0 then CreateThread(flushLogs) end
end)

CreateThread(function()
    if GetConvar('uhost_api_key', '') == '' then
        print('^3[' .. RESOURCE .. '] Warning: set "uhost_api_key" in server.cfg (set uhost_api_key "r2u_...")^7')
    end
    if not screenshotBasicReady() then
        print('^3[' .. RESOURCE .. '] screenshot-basic is not running: takeImage/takeServerImage will not work^7')
    end
end)
