# test-banners.ps1 (home page banners: public list, admin CRUD, reorder, access, image and href rules, audit)
# Run from the project root on fresh seed data while "npm run dev" is running. Uses curl.exe.
$base = 'http://localhost:4000/api/v1'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
function Call($method, $path, $token, $body) {
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true }
    if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $body) { $p.ContentType = 'application/json'; $p.Body = ($body | ConvertTo-Json -Compress) }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); headers = $r.Headers } }
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

$tmp = Join-Path $env:TEMP 'vh-banners'
node scripts/make-image-fixtures.mjs $tmp | Out-Null

# multipart with curl.exe: $file is "name;type=mime" or $null; $fields is a hashtable (sent with --form-string)
function Send($method, $path, $token, $file, $fields) {
    $out = Join-Path $tmp 'resp.json'
    if (Test-Path $out) { Remove-Item $out }
    $cargs = @('-s', '-o', $out, '-w', '%{http_code}', '-X', $method)
    if ($token) { $cargs += @('-H', "Authorization: Bearer $token") }
    if ($file) {
        $nameType = $file -split ';type=', 2
        $cargs += @('-F', "image=@$(Join-Path $tmp $nameType[0]);type=$($nameType[1])")
    }
    if ($fields) { foreach ($k in $fields.Keys) { $cargs += @('--form-string', "$k=$($fields[$k])") } }
    $code = & curl.exe @cargs "$base$path"
    $json = $null
    if (Test-Path $out) { try { $json = Get-Content $out -Raw | ConvertFrom-Json } catch { } }
    return @{ status = [int]$code; json = $json }
}
function Fields($title, $href) {
    return @{ titleEn = $title; titleBn = 'Banner BN'; textEn = 'Short text'; ctaEn = 'Shop now'; href = $href }
}

$admin = Login 'admin@vendorshub.test'
$customer = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test'

# ---- 1. empty start, public list ----
$pub = Call 'GET' '/banners' $null $null
Check 'public list: 200 without login' $pub.status 200
Check 'public list is empty on fresh seed' @($pub.json.data).Count 0
Check 'public list has a short Cache-Control' ([string]$pub.headers['Cache-Control']) 'public, max-age=60'

# ---- 2. access ----
Check 'admin list logged out: 401' (Call 'GET' '/admin/banners' $null $null).status 401
Check 'admin list as customer: 403' (Call 'GET' '/admin/banners' $customer $null).status 403
Check 'create as customer: 403' (Send 'POST' '/admin/banners' $customer 'valid.jpg;type=image/jpeg' (Fields 'A' '/')).status 403
Check 'create as shop owner: 403' (Send 'POST' '/admin/banners' $owner 'valid.jpg;type=image/jpeg' (Fields 'A' '/')).status 403

# ---- 3. create ----
$a = Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' (Fields 'First' '/markets')
Check 'create A: 201' $a.status 201
$b = Send 'POST' '/admin/banners' $admin 'valid.png;type=image/png' (Fields 'Second' '/products?sort=new')
Check 'create B (PNG): 201' $b.status 201
$c = Send 'POST' '/admin/banners' $admin 'valid.webp;type=image/webp' (Fields 'Third' '/shops')
Check 'create C (WebP): 201' $c.status 201
$idA = $a.json.data.id; $idB = $b.json.data.id; $idC = $c.json.data.id
Check 'image URL is our WebP' ($a.json.data.imageUrl -like 'http://localhost:4000/media/*.webp') $true
Check 'image is served' (FetchStatus $a.json.data.imageUrl) 200
Check 'sortOrder defaults to the end' $c.json.data.sortOrder 2
Check 'empty optional field is null' $a.json.data.textBn $null

# ---- 4. rejected input ----
Check 'no image: 400' (Send 'POST' '/admin/banners' $admin $null (Fields 'X' '/')).status 400
Check 'SVG: 400' (Send 'POST' '/admin/banners' $admin 'script.svg;type=image/svg+xml' (Fields 'X' '/')).status 400
Check 'GIF: 400' (Send 'POST' '/admin/banners' $admin 'anim.gif;type=image/gif' (Fields 'X' '/')).status 400
Check 'PDF sent as image/jpeg: 400' (Send 'POST' '/admin/banners' $admin 'doc.pdf;type=image/jpeg' (Fields 'X' '/')).status 400
Check 'HTML in a PNG name: 400' (Send 'POST' '/admin/banners' $admin 'page.png;type=image/png' (Fields 'X' '/')).status 400
Check 'over 3 MB: 413' (Send 'POST' '/admin/banners' $admin 'huge.jpg;type=image/jpeg' (Fields 'X' '/')).status 413
Check 'too small: 422' (Send 'POST' '/admin/banners' $admin 'small.jpg;type=image/jpeg' (Fields 'X' '/')).status 422
foreach ($h in @('https://evil.example', '//evil.example', '/\evil.example', 'javascript:alert(1)', 'data:text/html,x', 'markets', '/a b', ' javascript:alert(1)')) {
    Check "href '$h' is rejected" (Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' (Fields 'X' $h)).status 400
}
Check 'HTML in title: 400' (Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' (Fields '<b>x</b>' '/')).status 400
Check 'title over 80: 400' (Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' (Fields ('t' * 81) '/')).status 400
$long = Fields 'X' '/'; $long.ctaEn = 'c' * 31
Check 'cta over 30: 400' (Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' $long).status 400
$unk = Fields 'X' '/'; $unk.role = 'ADMIN'
Check 'unknown field: 400' (Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' $unk).status 400
Check 'still exactly 3 banners' @((Call 'GET' '/admin/banners' $admin $null).json.data).Count 3

# ---- 5. public list rules ----
Check 'public shows all 3' @((Call 'GET' '/banners' $null $null).json.data).Count 3
$p0 = @((Call 'GET' '/banners' $null $null).json.data)[0]
Check 'public order by sortOrder' $p0.id $idA
Check 'public has no admin fields' ($null -eq $p0.PSObject.Properties['isActive'] -and $null -eq $p0.PSObject.Properties['sortOrder']) $true
Check 'deactivate B: 200' (Send 'PATCH' "/admin/banners/$idB" $admin $null @{ isActive = 'false' }).status 200
$future = (Get-Date).ToUniversalTime().AddDays(2).ToString('o')
Check 'schedule C in the future: 200' (Call 'PATCH' "/admin/banners/$idC" $admin @{ startsAt = $future }).status 200
$ids = @((Call 'GET' '/banners' $null $null).json.data | ForEach-Object { $_.id })
Check 'public hides inactive and not-yet-started' (($ids -join ',') -eq $idA) $true
Check 'admin still lists all 3' @((Call 'GET' '/admin/banners' $admin $null).json.data).Count 3
Check 'endsAt before startsAt: 400' (Call 'PATCH' "/admin/banners/$idC" $admin @{ endsAt = (Get-Date).ToUniversalTime().AddDays(1).ToString('o') }).status 400
Check 'clear schedule and reactivate' (Call 'PATCH' "/admin/banners/$idC" $admin @{ startsAt = $null; isActive = $true }).status 200
Check 'reactivate B' (Call 'PATCH' "/admin/banners/$idB" $admin @{ isActive = $true }).status 200
for ($i = 0; $i -lt 3; $i++) { Send 'POST' '/admin/banners' $admin 'valid.jpg;type=image/jpeg' (Fields "Extra $i" '/') | Out-Null }
Check 'public returns at most 5' @((Call 'GET' '/banners' $null $null).json.data).Count 5

# ---- 6. update ----
Check 'update bad id: 400' (Call 'PATCH' '/admin/banners/not-a-uuid' $admin @{ titleEn = 'x' }).status 400
Check 'update unknown id: 404' (Call 'PATCH' '/admin/banners/00000000-0000-4000-8000-000000000000' $admin @{ titleEn = 'x' }).status 404
Check 'update bad href: 400' (Call 'PATCH' "/admin/banners/$idA" $admin @{ href = '//evil.example' }).status 400
Check 'update empty body: 400' (Call 'PATCH' "/admin/banners/$idA" $admin @{}).status 400
$oldUrl = $a.json.data.imageUrl
$u = Send 'PATCH' "/admin/banners/$idA" $admin 'replace.jpg;type=image/jpeg' @{ titleEn = 'First updated' }
Check 'replace image and title: 200' $u.status 200
Check 'title updated' $u.json.data.titleEn 'First updated'
Check 'new image URL' ($u.json.data.imageUrl -ne $oldUrl) $true
Check 'old image file is gone' (FetchStatus $oldUrl) 404
Check 'customer update: 403' (Call 'PATCH' "/admin/banners/$idA" $customer @{ titleEn = 'x' }).status 403

# ---- 7. reorder ----
$all = @((Call 'GET' '/admin/banners' $admin $null).json.data | ForEach-Object { $_.id })
$rev = @($all[($all.Count - 1)..0])
$r = Call 'PATCH' '/admin/banners/reorder' $admin @{ ids = $rev }
Check 'reorder: 200' $r.status 200
Check 'reorder applied' (@($r.json.data)[0].id) $rev[0]
Check 'reorder missing ids: 400' (Call 'PATCH' '/admin/banners/reorder' $admin @{ ids = @($rev[0]) }).status 400
Check 'reorder duplicate ids: 400' (Call 'PATCH' '/admin/banners/reorder' $admin @{ ids = @($rev[0], $rev[0]) }).status 400
Check 'reorder non-uuid: 400' (Call 'PATCH' '/admin/banners/reorder' $admin @{ ids = @('x') }).status 400
Check 'reorder as customer: 403' (Call 'PATCH' '/admin/banners/reorder' $customer @{ ids = $rev }).status 403

# ---- 8. delete ----
$imgB = $b.json.data.imageUrl
Check 'delete as customer: 403' (Call 'DELETE' "/admin/banners/$idB" $customer $null).status 403
Check 'delete bad id: 400' (Call 'DELETE' '/admin/banners/abc' $admin $null).status 400
Check 'delete B: 200' (Call 'DELETE' "/admin/banners/$idB" $admin $null).status 200
Check 'B image file is gone' (FetchStatus $imgB) 404
Check 'delete again: 404' (Call 'DELETE' "/admin/banners/$idB" $admin $null).status 404

# ---- 9. audit log ----
$logs = @((Call 'GET' "/admin/audit-logs?entityType=Banner&limit=50" $admin $null).json.data | ForEach-Object { $_.action })
foreach ($act in @('banner.created', 'banner.updated', 'banner.reordered', 'banner.deleted')) {
    Check "audit log has $act" ($logs -contains $act) $true
}

# clean up so other suites see no banners
foreach ($id in @((Call 'GET' '/admin/banners' $admin $null).json.data | ForEach-Object { $_.id })) { Call 'DELETE' "/admin/banners/$id" $admin $null | Out-Null }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
