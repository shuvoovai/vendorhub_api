# test-following-feed.ps1 (home page "From the shops": GET /products/following?scope=followed|unfollowed,
# follow rules, GET /users/me/following)
# Run from the project root on fresh seed data while "npm run dev" is running.
# Seed: TechZone (owner1; owner2 is staff), Dhaka Mobile House (owner2), Gadget Galaxy (owner3), all verified.
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
    if ($null -ne $body) { $p.ContentType = 'application/json'; $p.Body = ($body | ConvertTo-Json -Compress -Depth 5) }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); raw = $r.Content; headers = $r.Headers } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what not found" -ForegroundColor Red; exit 1 } }

# All feed items (every page of 24) for one user and scope
function Get-Feed($token, $scope) {
    $all = @(); $page = 1
    do {
        $r = Call 'GET' "/products/following?scope=$scope&limit=24&page=$page" $token $null
        $all += @($r.json.data)
        $pages = $r.json.meta.pagination.totalPages
        $page++
    } while ($page -le $pages)
    return , @($all | Where-Object { $_ })
}
# productId -> lowest in-stock price, over the given shops' storefronts (what the feed must show)
function Get-Expected($maps) {
    $exp = @{}
    foreach ($m in $maps) { foreach ($k in $m.Keys) { if (-not $exp.ContainsKey($k) -or $m[$k] -lt $exp[$k]) { $exp[$k] = $m[$k] } } }
    return $exp
}
function Get-ShopMap($slug) {
    $map = @{}
    foreach ($i in @((Call 'GET' "/shops/$slug/products?availableOnly=true&limit=50" $null $null).json.data)) {
        if ($i -and (-not $map.ContainsKey($i.product.id) -or $i.price -lt $map[$i.product.id])) { $map[$i.product.id] = [int]$i.price }
    }
    return $map
}
# every item is exactly the expected set, with the expected lowest price
function Check-Feed($label, $items, $expected) {
    Check "$label - product count" $items.Count $expected.Count
    $bad = @($items | Where-Object { -not $expected.ContainsKey($_.id) -or $_.lowestPrice -ne $expected[$_.id] })
    Check "$label - only products (and prices) from the expected shops" $bad.Count 0
    Check "$label - one card per product" (@($items | ForEach-Object { $_.id } | Select-Object -Unique).Count) $items.Count
}

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner1 = Login 'owner1@vendorshub.test'
$owner2 = Login 'owner2@vendorshub.test'
$tz = Get-ShopMap 'techzone-electronics'
$dmh = Get-ShopMap 'dhaka-mobile-house'
$gg = Get-ShopMap 'gadget-galaxy'
Need $tz.Count 'TechZone products'; Need $dmh.Count 'Dhaka Mobile House products'; Need $gg.Count 'Gadget Galaxy products'
foreach ($s in 'techzone-electronics', 'dhaka-mobile-house', 'gadget-galaxy') { Call 'DELETE' "/shops/$s/follow" $cust $null | Out-Null }

# ---- 1. access and validation ----
Check 'no token: 401' (Call 'GET' '/products/following' $null $null).status 401
Check 'invalid scope: 400' (Call 'GET' '/products/following?scope=all' $cust $null).status 400
Check 'limit 25: 400' (Call 'GET' '/products/following?limit=25' $cust $null).status 400
Check 'page 0: 400' (Call 'GET' '/products/following?page=0' $cust $null).status 400
$none = Call 'GET' '/products/following' $cust $null
Check 'following nobody: 200' $none.status 200
Check 'following nobody: empty "followed" (the default scope)' @($none.json.data).Count 0
Check 'Cache-Control private, no-store' ([string]$none.headers['Cache-Control']) 'private, no-store'
Check '"following" is not read as a product slug' ($none.json.meta.pagination.page) 1

# ---- 2. follow rules ----
Check 'follow TechZone: 200' (Call 'POST' '/shops/techzone-electronics/follow' $cust $null).status 200
$again = Call 'POST' '/shops/techzone-electronics/follow' $cust $null
Check 'following twice is not an error' $again.status 200
Check 'still following' $again.json.data.following $true
Check 'a malformed slug: 400' (Call 'POST' '/shops/Bad_Slug!/follow' $cust $null).status 400
Check 'an unknown shop: 404' (Call 'POST' '/shops/no-such-shop/follow' $cust $null).status 404
Check 'an owner cannot follow their own shop: 400' (Call 'POST' '/shops/techzone-electronics/follow' $owner1 $null).status 400
Check 'staff cannot follow their own shop: 400' (Call 'POST' '/shops/techzone-electronics/follow' $owner2 $null).status 400
Check 'unfollowing a shop not followed is fine' (Call 'DELETE' '/shops/gadget-galaxy/follow' $cust $null).status 200
$mine = @((Call 'GET' '/users/me/following' $cust $null).json.data)
Check '/users/me/following lists TechZone' (@($mine | Where-Object { $_.slug -eq 'techzone-electronics' }).Count) 1
Check '/users/me/following has id, slug, name, logoUrl' (($null -ne $mine[0].id) -and ($null -ne $mine[0].name) -and ($null -ne $mine[0].PSObject.Properties['logoUrl'])) $true
Check '/users/me/following without a token: 401' (Call 'GET' '/users/me/following' $null $null).status 401

# ---- 3. followed vs unfollowed ----
$followed = Get-Feed $cust 'followed'
Check-Feed 'followed = TechZone only' $followed $tz
Check 'followed: shopCount counts only TechZone' (@($followed | Where-Object { $_.shopCount -ne 1 }).Count) 0
$card = $followed[0]
foreach ($f in @('id', 'slug', 'title', 'brand', 'category', 'image', 'msrp', 'lowestPrice', 'highestPrice', 'shopCount', 'availability', 'bargainAvailable', 'bestListingId', 'createdAt')) {
    Check "card has $f" ($null -ne $card.PSObject.Properties[$f]) $true
}
Check 'no stock number in the cards' (@($followed | Where-Object { $_.PSObject.Properties['stockQty'] }).Count) 0
$unf = Get-Feed $cust 'unfollowed'
Check-Feed 'unfollowed = the other verified shops' $unf (Get-Expected @($dmh, $gg))
$tzOnly = @($tz.Keys | Where-Object { -not $dmh.ContainsKey($_) -and -not $gg.ContainsKey($_) })
Check 'unfollowed never shows a TechZone-only product' (@($unf | Where-Object { $tzOnly -contains $_.id }).Count) 0

# ---- 4. own shops are excluded (owner2 owns Dhaka Mobile House and is TechZone staff) ----
Check-Feed 'staff/owner: unfollowed = Gadget Galaxy only' (Get-Feed $owner2 'unfollowed') $gg

# ---- 5. unverified and inactive shops are hidden ----
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$uv = (Call 'POST' '/auth/register' $null @{ name = 'Feed Owner'; email = "feed$stamp@vendorshub.test"; password = 'Password123!'; role = 'SHOP_OWNER' }).json.data.accessToken
$uvShop = (Call 'POST' '/shops' $uv @{ name = "Feed Test $stamp"; addressLine = 'Road 3, Test Area, Dhaka'; phone = '01712345678' }).json.data
Need $uvShop.id 'the unverified shop'
$someProduct = @($tz.Keys)[0]
Need ((Call 'POST' "/shops/$($uvShop.id)/listings" $uv @{ productId = $someProduct; price = 1; availability = 'IN_STOCK' }).status -eq 201) 'the unverified listing'
Check 'customer follows the unverified shop' (Call 'POST' "/shops/$($uvShop.slug)/follow" $cust $null).status 200
Check-Feed 'unverified shop: followed unchanged' (Get-Feed $cust 'followed') $tz
Check-Feed 'unverified shop: unfollowed unchanged' (Get-Feed $cust 'unfollowed') (Get-Expected @($dmh, $gg))
$ggId = (Call 'GET' '/shops/gadget-galaxy' $null $null).json.data.id
Check 'admin deactivates Gadget Galaxy' (Call 'PATCH' "/admin/shops/$ggId/status" $admin @{ isActive = $false; reason = 'Feed test pause' }).status 200
Check-Feed 'inactive shop: unfollowed = Dhaka Mobile House only' (Get-Feed $cust 'unfollowed') $dmh
Check 'admin reactivates Gadget Galaxy' (Call 'PATCH' "/admin/shops/$ggId/status" $admin @{ isActive = $true; reason = 'Feed test done' }).status 200

# ---- 6. order and pagination ----
$p1 = Call 'GET' '/products/following?scope=unfollowed&limit=2&page=1' $cust $null
$p2 = Call 'GET' '/products/following?scope=unfollowed&limit=2&page=2' $cust $null
Check 'page 1 has 2 items' @($p1.json.data).Count 2
Check 'meta.pagination.limit' $p1.json.meta.pagination.limit 2
Check 'meta.pagination.total' $p1.json.meta.pagination.total (Get-Expected @($dmh, $gg)).Count
Check 'pages do not overlap' (@($p2.json.data | Where-Object { @($p1.json.data | ForEach-Object { $_.id }) -contains $_.id }).Count) 0
Check 'default limit is 8' $none.json.meta.pagination.limit 8

foreach ($s in 'techzone-electronics', $uvShop.slug) { Call 'DELETE' "/shops/$s/follow" $cust $null | Out-Null }
Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
