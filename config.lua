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
