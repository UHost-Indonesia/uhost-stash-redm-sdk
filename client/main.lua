-- UHost R2 SDK (client): screenshots via screenshot-basic, uploaded straight to the API
-- with one-time URLs issued by the server (the API key never reaches clients).

local RESOURCE = GetCurrentResourceName()
local pendingRpc = {}
local rpcCounter = 0

local function fail(message)
    error(RESOURCE .. ': ' .. message, 0)
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    return type(value) == 'table' and rawget(value, '__cfx_functionReference') ~= nil
end

local function rpc(action, payload)
    rpcCounter = rpcCounter + 1
    local requestId = rpcCounter
    local p = promise.new()
    pendingRpc[requestId] = p

    TriggerServerEvent(RESOURCE .. ':rpc', requestId, action, payload)
    SetTimeout(Config.RpcTimeoutMs, function()
        if pendingRpc[requestId] then
            pendingRpc[requestId] = nil
            p:reject(RESOURCE .. ': server did not respond')
        end
    end)
    return Citizen.Await(p)
end

RegisterNetEvent(RESOURCE .. ':rpc:result', function(requestId, ok, result)
    local p = pendingRpc[requestId]
    if not p then return end
    pendingRpc[requestId] = nil
    if ok then p:resolve(result) else p:reject(result) end
end)

local function screenshotUpload(url, options)
    if GetResourceState('screenshot-basic') ~= 'started' then fail('resource "screenshot-basic" is not started') end
    options = options or {}

    local p = promise.new()
    exports['screenshot-basic']:requestScreenshotUpload(url, 'file', {
        encoding = options.encoding or Config.Screenshot.encoding,
        quality = options.quality or Config.Screenshot.quality,
    }, function(text)
        local ok, resp = pcall(json.decode, text or '')
        if ok and type(resp) == 'table' and resp.status == 'ok' and resp.data then
            p:resolve(resp.data)
        else
            local message = ok and type(resp) == 'table' and resp.error or text
            p:reject(RESOURCE .. ': screenshot upload failed: ' .. tostring(message))
        end
    end)
    return Citizen.Await(p)
end

-- Server-initiated capture (takeServerImage)
RegisterNetEvent(RESOURCE .. ':capture', function(requestId, url, options)
    CreateThread(function()
        local ok, err = pcall(screenshotUpload, url, options)
        TriggerServerEvent(RESOURCE .. ':captureDone', requestId, (not ok) and tostring(err) or nil)
    end)
end)

local function takeImage(metadata, options)
    local presigned = rpc('takeImage', { metadata = metadata })
    local file = screenshotUpload(presigned.url, options)
    return { status = 'ok', id = file.id, url = file.url, data = file }
end

-- One-time upload URL for NUI uploads (recorded video/audio, photos, ...)
local function requestPresignedUrl(fileType, metadata)
    return rpc('presign', { fileType = fileType, metadata = metadata }).url
end

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

export('takeImage', takeImage)
export('requestPresignedUrl', requestPresignedUrl)
