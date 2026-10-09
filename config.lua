Config = {}

-- Print request details to the server/client console
Config.Debug = false

-- Screenshot settings passed to screenshot-basic
Config.Screenshot = {
    encoding = 'webp', -- 'webp' | 'jpg' | 'png'
    quality = 0.85,    -- 0.0 - 1.0
    timeoutMs = 15000, -- max wait for takeServerImage
}

-- Default folder per file type. Only used by Static/CDN buckets (standard
-- buckets are flat and ignore folders).
Config.Folders = {
    image = 'screenshots',
    video = 'videos',
    audio = 'audio',
}

-- Client export takeImage() (screenshot taken by the player's own client)
Config.AllowClientScreenshots = true

-- Client export requestPresignedUrl() (e.g. NUI that records video/audio)
Config.AllowClientPresignedUrls = true

-- Minimum delay between client-initiated requests per player (anti-spam)
Config.ClientCooldownMs = 3000

-- Add playerSource, playerName and identifiers to every upload's metadata
Config.AppendPlayerInfo = true

-- Identifier types never stored in metadata
Config.ExcludedIdentifiers = { ip = true }

-- Max wait for client -> server requests
Config.RpcTimeoutMs = 20000

-- Logs (dashboard → Logs). exports[...]:log() is always available; logs are
-- queued and sent in batches so a call never waits for the network.
Config.Logs = {
    flushIntervalMs = 2000, -- send queued logs this often
    batchSize = 100,        -- or as soon as this many are queued
    maxQueue = 2000,        -- kept while the API is unreachable (oldest dropped first)

    -- Built-in event logs
    playerJoins = true,     -- dataset "joins": joined / left (with the drop reason)
    chat = false,           -- dataset "chat": chat messages (default chat resource)
    txAdmin = true,         -- dataset "txadmin": kicks, warns, bans, announcements, restarts
}
