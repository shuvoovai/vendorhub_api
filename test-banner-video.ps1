# test-banner-video.ps1 (home page banners: a photo OR an MP4/WebM video)
# Run from the project root while "npm run dev" is running. Uses curl.exe. Leaves no banners behind.
$base = 'http://localhost:4000/api/v1'
$origin = 'http://localhost:4000'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
function Call($method, $path, $token, $body) {
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true }
    if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)) }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json) } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function FetchStatus($url) {
    try { return [int](Invoke-WebRequest $url -UseBasicParsing).StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 }
}

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$tmp = Join-Path $env:TEMP 'vh-banner-video'
node scripts/make-image-fixtures.mjs $tmp | Out-Null

# Video fixtures: only the first bytes matter (the type check reads the magic number).
function WriteBytes($name, [byte[]]$head, [int]$size) {
    $buf = New-Object byte[] $size
    [Array]::Copy($head, $buf, $head.Length)
    [IO.File]::WriteAllBytes((Join-Path $tmp $name), $buf)
}
$a = [Text.Encoding]::ASCII
$mp4Head = [byte[]](@(0, 0, 0, 24) + $a.GetBytes('ftypisom') + @(0, 0, 2, 0) + $a.GetBytes('isomiso2'))
$webmHead = [byte[]](@(0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0x82, 0x84) + $a.GetBytes('webm'))
$mkvHead = [byte[]](@(0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88) + $a.GetBytes('matroska'))
$heicHead = [byte[]](@(0, 0, 0, 24) + $a.GetBytes('ftypheic') + @(0, 0, 0, 0) + $a.GetBytes('mif1heic'))
WriteBytes 'clip.mp4' $mp4Head 50000
WriteBytes 'clip.webm' $webmHead 40000
WriteBytes 'movie.mkv' $mkvHead 4000
WriteBytes 'photo.heic' $heicHead 4000
WriteBytes 'huge.mp4' $mp4Head (21 * 1024 * 1024)
[IO.File]::WriteAllText((Join-Path $tmp 'fake.mp4'), 'this is plain text, not a video')

# multipart with curl.exe; $files is "field=name;type=mime" entries, $fields is a hashtable (sent with --form-string)
function Send($method, $path, $token, $files, $fields) {
    $out = Join-Path $tmp 'resp.json'
    if (Test-Path $out) { Remove-Item $out }
    $cargs = @('-s', '-o', $out, '-w', '%{http_code}', '-X', $method)
    if ($token) { $cargs += @('-H', "Authorization: Bearer $token") }
    foreach ($f in @($files | Where-Object { $_ })) {
        $field, $rest = $f -split '=', 2
        $nameType = $rest -split ';type=', 2
        $cargs += @('-F', "$field=@$(Join-Path $tmp $nameType[0]);type=$($nameType[1])")
    }
    if ($fields) { foreach ($k in $fields.Keys) { $cargs += @('--form-string', "$k=$($fields[$k])") } }
    $code = & curl.exe @cargs "$base$path"
    $json = $null
    if (Test-Path $out) { try { $json = Get-Content $out -Raw | ConvertFrom-Json } catch { } }
    return @{ status = [int]$code; json = $json }
}
function Fields($title) { return @{ titleEn = $title; titleBn = 'Banner BN'; href = '/markets' } }
$img = 'image=valid.jpg;type=image/jpeg'
# headers of a media URL: "-D -" prints them; $range is e.g. "0-9" or $null
function Head($url, $range) {
    $cargs = @('-s', '-o', 'NUL', '-D', '-')
    if ($range) { $cargs += @('-r', $range) }
    $lines = & curl.exe @cargs $url
    $h = @{ status = 0 }
    foreach ($l in $lines) {
        if ($l -match '^HTTP/\S+ (\d{3})') { $h.status = [int]$Matches[1] }
        elseif ($l -match '^([^:]+):\s*(.*)$') { $h[$Matches[1].ToLower()] = $Matches[2].Trim() }
    }
    return $h
}

$admin = Login 'admin@vendorshub.test'

# ---- 1. exactly one file; type and size checks ----
$mp4 = 'video=clip.mp4;type=video/mp4'
Check 'no file: 400' (Send 'POST' '/admin/banners' $admin $null (Fields 'None')).status 400
Check 'image AND video: 400' (Send 'POST' '/admin/banners' $admin @($img, $mp4) (Fields 'Both')).status 400
Check 'text file named .mp4: 400' (Send 'POST' '/admin/banners' $admin @('video=fake.mp4;type=video/mp4') (Fields 'Fake')).status 400
Check 'HEIC sent as video/mp4: 400' (Send 'POST' '/admin/banners' $admin @('video=photo.heic;type=video/mp4') (Fields 'Heic')).status 400
Check 'Matroska sent as video/webm: 400' (Send 'POST' '/admin/banners' $admin @('video=movie.mkv;type=video/webm') (Fields 'Mkv')).status 400
Check 'JPEG in the video field: 400' (Send 'POST' '/admin/banners' $admin @('video=valid.jpg;type=video/mp4') (Fields 'Jpeg')).status 400
Check 'video over 20 MB: 413' (Send 'POST' '/admin/banners' $admin @('video=huge.mp4;type=video/mp4') (Fields 'Huge')).status 413
Check 'photo over 3 MB: 413' (Send 'POST' '/admin/banners' $admin @('image=huge.jpg;type=image/jpeg') (Fields 'Big')).status 413
Check 'two videos: 400' (Send 'POST' '/admin/banners' $admin @($mp4, 'video=clip.webm;type=video/webm') (Fields 'Two')).status 400
Check 'nothing created by bad requests' (@((Call 'GET' '/admin/banners' $admin $null).json.data | Where-Object { $_ }).Count) 0
Check 'other photo routes keep 5 MB (21 MB to a market image: 413)' (Send 'PUT' '/admin/markets/00000000-0000-4000-8000-000000000000/image' $admin @('image=huge.mp4;type=image/jpeg') $null).status 413

# ---- 2. create a video banner (the type comes from the bytes, not the name or header) ----
$f = Fields 'Video banner'; $f.startsAt = ''; $f.endsAt = (Get-Date).AddDays(30).ToString('yyyy-MM-dd') + 'T00:00:00+06:00'
$r = Send 'POST' '/admin/banners' $admin @('video=clip.mp4;type=application/octet-stream') $f
Check 'create video banner: 201' $r.status 201
$id = $r.json.data.id
$v1 = $r.json.data.videoUrl
Check 'videoUrl is a random .mp4 on /media' ($v1 -match '^http://localhost:4000/media/[0-9a-f-]{36}\.mp4$') $true
Check 'uploaded name not used' ($v1 -match 'clip') $false
Check 'imageUrl null' ($null -eq $r.json.data.imageUrl) $true
Check 'thumbUrl null' ($null -eq $r.json.data.thumbUrl) $true
Check 'empty startsAt is null' ($null -eq $r.json.data.startsAt) $true
Check 'endsAt with +06:00 is parsed' (([datetime]$r.json.data.endsAt).ToUniversalTime().ToString('HH:mm')) '18:00'
Check 'admin answer has no videoKey' ($null -eq $r.json.data.PSObject.Properties['videoKey']) $true
$pub = @((Call 'GET' '/banners' $null $null).json.data | Where-Object { $_.id -eq $id })
Check 'public: videoUrl' $pub[0].videoUrl $v1
Check 'public: imageUrl null' ($null -eq $pub[0].imageUrl) $true
Check 'admin list: videoUrl' (@((Call 'GET' '/admin/banners' $admin $null).json.data | Where-Object { $_.id -eq $id })[0].videoUrl) $v1
$r = Send 'POST' '/admin/banners' $admin @($img) (Fields 'Photo banner')
Check 'create photo banner: 201' $r.status 201
$photoId = $r.json.data.id
Check 'photo banner: videoUrl null' ($null -eq $r.json.data.videoUrl) $true
Check 'photo banner: thumbUrl set' ([bool]$r.json.data.thumbUrl) $true

# ---- 3. serving: type, ranges, headers ----
$h = Head $v1 $null
Check 'video: 200' $h.status 200
Check 'Content-Type video/mp4' $h['content-type'] 'video/mp4'
Check 'Accept-Ranges bytes' $h['accept-ranges'] 'bytes'
Check 'nosniff' $h['x-content-type-options'] 'nosniff'
Check 'cached like images' ($h['cache-control'] -match 'max-age=31536000' -and $h['cache-control'] -match 'immutable') $true
Check 'full length' $h['content-length'] '50000'
$h = Head $v1 '0-9'
Check 'Range: 206' $h.status 206
Check 'Range: Content-Range' $h['content-range'] 'bytes 0-9/50000'
Check 'Range: 10 bytes' $h['content-length'] '10'
Check 'Range past the end: 416' (Head $v1 '60000-60010').status 416
Check 'other extension: 404' (FetchStatus ($v1 -replace '\.mp4$', '.mov')) 404

# ---- 4. PATCH: switch between video and photo, JSON isActive ----
Check 'PATCH with both files: 400' (Send 'PATCH' "/admin/banners/$id" $admin @($img, $mp4) $null).status 400
Check 'removeVideo is no longer a field: 400' (Send 'PATCH' "/admin/banners/$id" $admin $null @{ removeVideo = 'true' }).status 400
$r = Send 'PATCH' "/admin/banners/$id" $admin @('video=clip.webm;type=video/webm') $null
Check 'video -> new WebM: 200' $r.status 200
$v2 = $r.json.data.videoUrl
Check 'new .webm url' ($v2 -match '\.webm$') $true
Check 'WebM Content-Type' (Head $v2 $null)['content-type'] 'video/webm'
Check 'old MP4 file deleted' (FetchStatus $v1) 404
Check 'bad video on PATCH: 400' (Send 'PATCH' "/admin/banners/$id" $admin @('video=fake.mp4;type=video/mp4') $null).status 400
Check 'video kept after a bad PATCH' (FetchStatus $v2) 200
$t = Send 'PATCH' "/admin/banners/$id" $admin $null @{ titleEn = 'Renamed' }
Check 'text only: 200' $t.status 200
Check 'text only keeps the video' $t.json.data.videoUrl $v2
$j = Call 'PATCH' "/admin/banners/$id" $admin @{ isActive = $false }
Check 'JSON { isActive } alone: 200' $j.status 200
Check 'hidden' $j.json.data.isActive $false
Check 'video kept on JSON PATCH' $j.json.data.videoUrl $v2
Check 'show again' (Call 'PATCH' "/admin/banners/$id" $admin @{ isActive = $true }).json.data.isActive $true
$r = Send 'PATCH' "/admin/banners/$id" $admin @($img) $null
Check 'video -> photo: 200' $r.status 200
Check 'now videoUrl null' ($null -eq $r.json.data.videoUrl) $true
$imgUrl = $r.json.data.imageUrl
$thumb = $r.json.data.thumbUrl
Check 'now has a photo' (FetchStatus $imgUrl) 200
Check 'WebM file deleted' (FetchStatus $v2) 404
$r = Send 'PATCH' "/admin/banners/$id" $admin @($mp4) $null
Check 'photo -> video: 200' $r.status 200
$v3 = $r.json.data.videoUrl
Check 'imageUrl null again' ($null -eq $r.json.data.imageUrl) $true
Check 'thumbUrl null again' ($null -eq $r.json.data.thumbUrl) $true
Check 'photo file deleted' (FetchStatus $imgUrl) 404
Check 'thumb file deleted' (FetchStatus $thumb) 404
Check 'public: imageUrl null' ($null -eq @((Call 'GET' '/banners' $null $null).json.data | Where-Object { $_.id -eq $id })[0].imageUrl) $true

# ---- 5. delete removes whichever files exist ----
Check 'delete video banner: 200' (Call 'DELETE' "/admin/banners/$id" $admin $null).status 200
Check 'video file deleted with the banner' (FetchStatus $v3) 404

# ---- 6. audit log: media type ----
$logs = @((Call 'GET' "/admin/audit-logs?entityType=Banner&entityId=$id&limit=50" $admin $null).json.data)
Check 'created: mediaType video' (@($logs | Where-Object { $_.action -eq 'banner.created' -and $_.meta.mediaType -eq 'video' }).Count) 1
Check 'updated to a photo: mediaType image' (@($logs | Where-Object { $_.action -eq 'banner.updated' -and $_.meta.mediaType -eq 'image' -and $_.meta.previousMediaType -eq 'video' }).Count) 1
Check 'updated to a video: mediaType video' (@($logs | Where-Object { $_.action -eq 'banner.updated' -and $_.meta.mediaReplaced -and $_.meta.mediaType -eq 'video' }).Count) 2
Check 'photo banner created: mediaType image' (@((Call 'GET' "/admin/audit-logs?entityType=Banner&entityId=$photoId&limit=50" $admin $null).json.data | Where-Object { $_.meta.mediaType -eq 'image' }).Count) 1

foreach ($b in @((Call 'GET' '/admin/banners' $admin $null).json.data | ForEach-Object { $_.id })) { Call 'DELETE' "/admin/banners/$b" $admin $null | Out-Null }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
