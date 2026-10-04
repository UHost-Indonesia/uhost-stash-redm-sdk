# UHost R2 SDK untuk RedM

Resource Lua untuk upload **screenshot, video, dan audio** dari server RedM ke **[UHost R2](https://r2.uhost.id)**.

- Murni Lua, tanpa build step.
- **API key hanya ada di server.** Client meng-upload langsung ke UHost R2 lewat *presigned URL* sekali pakai, jadi bandwidth server game tidak terpakai dan key tidak bocor ke pemain.
- Hasil `takeServerImage` diverifikasi di server, jadi client yang dimodifikasi tidak bisa mengirim URL palsu.
- Metadata pemain (`playerSource`, `playerName`, `identifiers`) otomatis ditambahkan dan tampil di dashboard UHost R2. Identifier `ip` tidak pernah disimpan.

## Instalasi

1. Di dashboard [r2.uhost.id](https://r2.uhost.id), buat bucket. Disarankan tipe **Static / CDN** supaya file tersusun per folder: `screenshots/`, `videos/`, `audio/`.
2. Buka **API Keys** → **Create key**, lalu pilih bucket tadi supaya key terikat ke bucket itu.
3. Download repo ini ([ZIP](https://github.com/UHost-Indonesia/uhost-r2-redm-sdk/archive/refs/heads/main.zip) atau `git clone`), lalu letakkan di folder `resources/` dengan nama folder **`uhost-r2-redm-sdk`**. Nama folder menentukan nama export (`exports['uhost-r2-redm-sdk']`).
4. Tambahkan ke `server.cfg`:

```cfg
ensure screenshot-basic
ensure uhost-r2-redm-sdk

set uhost_api_key "r2u_xxxxxxxxxxxxxxxxxxxxxxxx"
set uhost_api_url "https://r2.uhost.id"
# Hanya kalau API key TIDAK terikat ke satu bucket:
# set uhost_bucket "nama-bucket"
```

> Gunakan `set`, **bukan** `setr`. `setr` mereplikasi nilai ke semua pemain, sehingga API key jadi terbaca client.

`screenshot-basic` hanya dibutuhkan untuk fitur screenshot (`takeImage` / `takeServerImage`). Pastikan build `screenshot-basic` yang dipakai mendukung RedM (`rdr3`).

## Export server

Semua export **memblok thread pemanggil** di Lua (pakai di dalam `CreateThread` atau event handler) dan mengembalikan **Promise** kalau dipanggil dari JS.
Kalau argumen terakhir berupa function, export berjalan dalam mode callback: `cb(result, err)`.

Hasil upload: `{ status = 'ok', id = '...', url = 'https://...', data = { id, url, key, type, size, metadata, ... } }`.

### `takeServerImage(playerSource, metadata?, options?, timeoutMs?)`

Ambil screenshot layar pemain, misalnya untuk anticheat atau laporan.

```lua
local ok, res = pcall(function()
    return exports['uhost-r2-redm-sdk']:takeServerImage(source, { reason = 'report #12' })
end)
if ok then
    print('Screenshot: ' .. res.url)
else
    print('Gagal: ' .. res)
end
```

`options`: `{ path = 'reports', filename = 'nama.webp', encoding = 'jpg', quality = 0.9 }`, semuanya opsional.

Mode callback:

```lua
exports['uhost-r2-redm-sdk']:takeServerImage(source, nil, nil, nil, function(res, err)
    if err then return print(err) end
    print(res.url)
end)
```

JavaScript:

```js
const res = await exports['uhost-r2-redm-sdk'].takeServerImage(source, { reason: "anticheat" });
console.log(res.url);
```

### `uploadImage(data, options?)` / `uploadFile(data, options?)`

Upload dari server. `data` boleh berupa data URI (`data:image/png;base64,...`), string base64, atau byte mentah.

```lua
local res = exports['uhost-r2-redm-sdk']:uploadImage(dataUri, {
    fileName = 'evidence.png', -- opsional; di bucket static menjadi nama file persis
    path = 'evidence',         -- opsional; folder (bucket static)
    metadata = { case = 7 },
})
```

### `requestPresignedUrl(fileType, options?)`

Menghasilkan URL upload sekali pakai (berlaku 15 menit) untuk `'image'`, `'video'`, atau `'audio'`. File dengan tipe lain ditolak.
Kirim URL-nya ke NUI, lalu NUI meng-upload langsung tanpa API key.

```lua
local url = exports['uhost-r2-redm-sdk']:requestPresignedUrl('video', {
    metadata = { clip = 'heist' },
    expiresIn = 600, -- detik, opsional
})
```

### `getFile(idOrKey)`, `listFiles(query?)`, `deleteFile(idOrKey)`

```lua
local file = exports['uhost-r2-redm-sdk']:getFile('screenshots/ABCD1234.webp')
local page = exports['uhost-r2-redm-sdk']:listFiles({ type = 'image', path = 'screenshots', page = 1, limit = 50 })
-- page.data = list file, page.pagination = { page, limit, total }
exports['uhost-r2-redm-sdk']:deleteFile(file.id)
```

## Export client

### `takeImage(metadata?, options?)`

Pemain mengambil screenshot sendiri, misalnya untuk kamera, foto profil, atau bukti laporan.

```lua
CreateThread(function()
    local res = exports['uhost-r2-redm-sdk']:takeImage({ app = 'camera' })
    print(res.url)
end)
```

### `requestPresignedUrl(fileType, metadata?)`

Untuk NUI yang merekam video/audio sendiri (misalnya `MediaRecorder`). File selalu masuk ke folder `Config.Folders` dengan nama unik, sehingga client tidak bisa menimpa file lain.

```lua
-- client.lua
RegisterNUICallback('getUploadUrl', function(data, cb)
    CreateThread(function()
        local ok, url = pcall(function()
            return exports['uhost-r2-redm-sdk']:requestPresignedUrl(data.fileType)
        end)
        cb(ok and { url = url } or { error = url })
    end)
end)
```

```js
// NUI (html/js)
const { url } = await fetch(`https://${GetParentResourceName()}/getUploadUrl`, {
  method: "POST",
  body: JSON.stringify({ fileType: "video" }),
}).then((r) => r.json());

const form = new FormData();
form.append("file", recordedBlob, "clip.webm");
const res = await fetch(url, { method: "POST", body: form }).then((r) => r.json());
console.log(res.data.url);
```

## Contoh integrasi

SDK ini adalah resource "library": ia tidak punya fitur yang terlihat pemain, tapi menyediakan export yang dipanggil resource lain. Semua contoh di bawah ditulis di **resource kamu sendiri**.

### 1. Hubungkan resource kamu ke SDK

Tambahkan dependency di `fxmanifest.lua` resource kamu supaya SDK selalu start lebih dulu:

```lua
dependency 'uhost-r2-redm-sdk'
```

Supaya pemanggilan lebih ringkas, simpan export-nya ke variabel lokal:

```lua
local R2 = exports['uhost-r2-redm-sdk']
```

### 2. Report pemain + bukti screenshot (server)

Saat pemain membuat report, server mengambil screenshot layar pemain itu dan menyimpan link-nya.

```lua
local R2 = exports['uhost-r2-redm-sdk']

RegisterCommand('report', function(source, args)
    local reason = table.concat(args, ' ')
    if reason == '' then return end

    local ok, res = pcall(function()
        return R2:takeServerImage(source, { reason = reason }, { path = 'reports' })
    end)

    if not ok then
        print(('Report dari %s gagal mengambil screenshot: %s'):format(GetPlayerName(source), res))
        return
    end

    -- Simpan ke database / kirim ke panel admin
    print(('Report dari %s: %s\nBukti: %s'):format(GetPlayerName(source), reason, res.url))
end, false)
```

### 3. Screenshot otomatis untuk anticheat (server)

Ambil bukti sebelum mengambil tindakan. Mode callback cocok kalau tidak ingin memblok thread.

```lua
local R2 = exports['uhost-r2-redm-sdk']

AddEventHandler('myanticheat:detected', function(playerId, detection)
    R2:takeServerImage(playerId, { detection = detection }, { path = 'anticheat' }, 10000, function(res, err)
        local evidence = res and res.url or ('tidak ada screenshot: ' .. tostring(err))
        print(('[anticheat] %s terdeteksi %s | %s'):format(GetPlayerName(playerId), detection, evidence))
        -- DropPlayer(playerId, 'Cheat terdeteksi')
    end)
end)
```

### 4. Kamera / foto oleh pemain (client → server)

Pemain mengambil foto dari layarnya sendiri, lalu link-nya dikirim ke server untuk disimpan.

```lua
-- client.lua
local R2 = exports['uhost-r2-redm-sdk']

RegisterCommand('foto', function()
    CreateThread(function()
        local ok, res = pcall(function()
            return R2:takeImage({ app = 'camera' })
        end)
        if ok then
            TriggerServerEvent('mycamera:savePhoto', res.url)
        else
            print('Gagal mengambil foto: ' .. res)
        end
    end)
end)
```

```lua
-- server.lua
RegisterNetEvent('mycamera:savePhoto', function(url)
    local src = source
    -- Hanya terima link dari UHost R2
    if type(url) ~= 'string' or not url:find('^https://r2%.uhost%.id/') then return end
    print(('%s menyimpan foto: %s'):format(GetPlayerName(src), url))
end)
```

### 5. Poster buronan untuk sheriff (server)

Ambil foto pemain untuk poster *wanted* dan simpan di folder terpisah. Tambahkan pengecekan job/izin sesuai framework kamu (VORP, RSG, RedEM:RP, dan lainnya).

```lua
local R2 = exports['uhost-r2-redm-sdk']

RegisterNetEvent('mysheriff:createWanted', function(targetId, bounty)
    local sheriff = source
    -- if not isSheriff(sheriff) then return end   -- cek job sesuai framework kamu

    local ok, res = pcall(function()
        return R2:takeServerImage(targetId, { bounty = bounty, sheriff = GetPlayerName(sheriff) }, { path = 'wanted' })
    end)
    if ok then
        TriggerClientEvent('mysheriff:posterCreated', -1, GetPlayerName(targetId), bounty, res.url)
    end
end)
```

### 6. Simpan link ke database (oxmysql)

```lua
local R2 = exports['uhost-r2-redm-sdk']

local function savePhoto(playerId, identifier)
    local res = R2:takeServerImage(playerId, nil, { path = 'photos' })
    MySQL.insert.await('INSERT INTO player_photos (identifier, url, file_id) VALUES (?, ?, ?)', {
        identifier, res.url, res.id,
    })
    return res.url
end

-- Hapus juga file-nya di UHost R2 saat datanya dihapus
local function deletePhoto(fileId)
    exports['uhost-r2-redm-sdk']:deleteFile(fileId)
    MySQL.update.await('DELETE FROM player_photos WHERE file_id = ?', { fileId })
end
```

### 7. Rekam video / voice note dari NUI

Alurnya: NUI meminta URL upload ke client script, client script memanggil `requestPresignedUrl`, lalu NUI meng-upload hasil rekaman langsung ke UHost R2. Contoh lengkapnya ada di bagian [`requestPresignedUrl` (client)](#requestpresignedurlfiletype-metadata).
File otomatis masuk ke folder `videos/` atau `audio/` (atur di `Config.Folders`).

### 8. Dari resource JavaScript

```js
const R2 = exports["uhost-r2-redm-sdk"];

onNet("myresource:capture", async () => {
  const src = global.source;
  try {
    const res = await R2.takeServerImage(src, { reason: "js-example" });
    console.log(`Screenshot: ${res.url}`);
  } catch (err) {
    console.error(err);
  }
});
```

## Log ke Discord

Log upload dan hapus file **tidak perlu diatur di SDK**. Aktifkan per bucket di dashboard UHost R2:

1. Di Discord: **Channel settings → Integrations → Webhooks → New Webhook → Copy Webhook URL**.
2. Di [r2.uhost.id](https://r2.uhost.id): buka bucket → **Discord webhook** → tempel URL → **Add webhook**.
3. Klik **Send test** untuk memastikan pesannya masuk. Pilih event yang dikirim (**Upload** / **Delete**), dan matikan sementara lewat tombol **Active** kapan saja.

Setiap log berisi nama file, ukuran, preview gambar, nama dan ID pemain, identifier, serta metadata yang kamu kirim (misalnya `reason` di contoh report). Log dari banyak upload sekaligus otomatis digabung supaya tidak terkena rate limit Discord.

## Konfigurasi (`config.lua`)

| Opsi | Default | Keterangan |
|---|---|---|
| `Config.Screenshot.encoding` | `'webp'` | `'webp'`, `'jpg'`, atau `'png'` |
| `Config.Screenshot.quality` | `0.85` | 0.0 - 1.0 |
| `Config.Screenshot.timeoutMs` | `15000` | batas waktu `takeServerImage` |
| `Config.Folders` | `screenshots` / `videos` / `audio` | folder default per tipe (bucket static) |
| `Config.AllowClientScreenshots` | `true` | izinkan export client `takeImage` |
| `Config.AllowClientPresignedUrls` | `true` | izinkan export client `requestPresignedUrl` |
| `Config.ClientCooldownMs` | `3000` | jeda minimum antar request dari satu pemain |
| `Config.AppendPlayerInfo` | `true` | tambahkan info pemain ke metadata |
| `Config.ExcludedIdentifiers` | `{ ip = true }` | identifier yang tidak disimpan |

## Upload langsung lewat HTTP

Resource lain juga bisa langsung memakai API UHost R2 tanpa SDK ini (misalnya dari kode server), dengan header `Authorization: <api key>`:

| Endpoint | Fungsi |
|---|---|
| `POST https://r2.uhost.id/api/v3/file` | upload multipart (field `file`, opsional `path`, `filename`, `metadata`) |
| `POST https://r2.uhost.id/api/v3/file/base64` | upload JSON `{ base64, filename?, path?, metadata? }` |
| `GET https://r2.uhost.id/api/v3/file/presigned-url?fileType=image` | buat URL upload sekali pakai |
| `GET https://r2.uhost.id/api/v3/file?type=image&path=screenshots` | daftar file |
| `GET` / `DELETE https://r2.uhost.id/api/v3/file/<id atau key>` | detail / hapus file |

Respons upload: `{ "status": "ok", "data": { "id": "...", "url": "https://..." } }`. Kalau API key tidak terikat ke satu bucket, tambahkan `?bucket=<nama>`.

## Batasan

- Maksimum ukuran per file mengikuti server UHost R2 (default 500 MB). Lewat Cloudflare, satu request dibatasi 100 MB.
- Rate limit diatur per API key di dashboard (**API Keys → ikon pensil**). Defaultnya 60 request/menit, dan kamu bisa menurunkannya sendiri. Untuk batas yang lebih tinggi, hubungi admin UHost. Satu screenshot lewat SDK memakai sekitar 3 request.

## Lisensi

[MIT](LICENSE) © UHost Indonesia
