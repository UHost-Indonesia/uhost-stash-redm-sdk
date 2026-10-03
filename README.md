# UHost R2 SDK untuk RedM

Resource Lua untuk upload **screenshot, video, dan audio** dari server RedM ke **[UHost R2](https://r2.uhost.id)**.

- Murni Lua, tanpa build step.
- **API key hanya ada di server.** Client meng-upload langsung ke UHost R2 lewat *presigned URL* sekali pakai, jadi bandwidth server game tidak terpakai dan key tidak bocor ke pemain.
- Hasil `takeServerImage` diverifikasi di server, jadi client yang dimodifikasi tidak bisa mengirim URL palsu.
- Metadata pemain (`playerSource`, `playerName`, `identifiers`) otomatis ditambahkan dan tampil di dashboard UHost R2. Identifier `ip` tidak pernah disimpan.

## Instalasi

1. Di dashboard [r2.uhost.id](https://r2.uhost.id), buat bucket. Disarankan tipe **Static / CDN** supaya file tersusun per folder: `screenshots/`, `videos/`, `audio/`.
2. Buka **API Keys** → **Create key**, lalu pilih bucket tadi supaya key terikat ke bucket itu.
3. Download repo ini ([ZIP](https://github.com/UHost-Indonesia/uhost-r2-redm-sdk/archive/refs/heads/main.zip) atau `git clone`), lalu letakkan di folder `resources/` dengan nama folder **`uhsdk`**. Nama folder menentukan nama export (`exports.uhsdk`).
4. Tambahkan ke `server.cfg`:

```cfg
ensure screenshot-basic
ensure uhsdk

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
    return exports.uhsdk:takeServerImage(source, { reason = 'report #12' })
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
exports.uhsdk:takeServerImage(source, nil, nil, nil, function(res, err)
    if err then return print(err) end
    print(res.url)
end)
```

JavaScript:

```js
const res = await exports.uhsdk.takeServerImage(source, { reason: "anticheat" });
console.log(res.url);
```

### `uploadImage(data, options?)` / `uploadFile(data, options?)`

Upload dari server. `data` boleh berupa data URI (`data:image/png;base64,...`), string base64, atau byte mentah.

```lua
local res = exports.uhsdk:uploadImage(dataUri, {
    fileName = 'evidence.png', -- opsional; di bucket static menjadi nama file persis
    path = 'evidence',         -- opsional; folder (bucket static)
    metadata = { case = 7 },
})
```

### `requestPresignedUrl(fileType, options?)`

Menghasilkan URL upload sekali pakai (berlaku 15 menit) untuk `'image'`, `'video'`, atau `'audio'`. File dengan tipe lain ditolak.
Kirim URL-nya ke NUI, lalu NUI meng-upload langsung tanpa API key.

```lua
local url = exports.uhsdk:requestPresignedUrl('video', {
    metadata = { clip = 'heist' },
    expiresIn = 600, -- detik, opsional
})
```

### `getFile(idOrKey)`, `listFiles(query?)`, `deleteFile(idOrKey)`

```lua
local file = exports.uhsdk:getFile('screenshots/ABCD1234.webp')
local page = exports.uhsdk:listFiles({ type = 'image', path = 'screenshots', page = 1, limit = 50 })
-- page.data = list file, page.pagination = { page, limit, total }
exports.uhsdk:deleteFile(file.id)
```

## Export client

### `takeImage(metadata?, options?)`

Pemain mengambil screenshot sendiri, misalnya untuk kamera, foto profil, atau bukti laporan.

```lua
CreateThread(function()
    local res = exports.uhsdk:takeImage({ app = 'camera' })
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
            return exports.uhsdk:requestPresignedUrl(data.fileType)
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
- Rate limit per API key default 60 request/menit. Hubungi admin UHost kalau server kamu sering mengambil screenshot.
