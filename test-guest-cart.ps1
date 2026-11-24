# test-guest-cart.ps1 (guest cart by httpOnly cookie, merge after login, bestListingId on product cards)
# Run from the project root on fresh seed data while "npm run dev" is running. Uses curl.exe with cookie jars.
$base = 'http://localhost:4000/api/v1'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$tmp = Join-Path $env:TEMP 'vh-guest-cart'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory $tmp | Out-Null

# One request with curl.exe. $jar: a cookie jar file name (read and written) or $null; $token: Bearer or $null.
# Returns status, json, and the Set-Cookie header for vh_guest_cart (or '').
function Req($method, $path, $jar, $token, $body) {
    $out = Join-Path $tmp 'resp.json'; $hdr = Join-Path $tmp 'resp.hdr'
    foreach ($f in @($out, $hdr)) { if (Test-Path $f) { Remove-Item $f } }
    $cargs = @('-s', '-o', $out, '-D', $hdr, '-w', '%{http_code}', '-X', $method)
    if ($jar) { $j = Join-Path $tmp $jar; $cargs += @('-b', $j, '-c', $j) }
    if ($token) { $cargs += @('-H', "Authorization: Bearer $token") }
    if ($null -ne $body) {
        $bf = Join-Path $tmp 'body.json'
        [IO.File]::WriteAllText($bf, ($body | ConvertTo-Json -Compress -Depth 5))
        $cargs += @('-H', 'Content-Type: application/json', '--data-binary', "@$bf")
    }
    $code = & curl.exe @cargs "$base$path"
    $json = $null
    if (Test-Path $out) { try { $json = Get-Content $out -Raw | ConvertFrom-Json } catch { } }
    $setCookie = ''
    if (Test-Path $hdr) { $setCookie = [string](@(Get-Content $hdr | Where-Object { $_ -match '^Set-Cookie:\s*vh_guest_cart=' }) | Select-Object -First 1) }
    return @{ status = [int]$code; json = $json; setCookie = $setCookie }
}
# the cookie value curl stored in a jar
function JarValue($jar) {
    $j = Join-Path $tmp $jar
    if (-not (Test-Path $j)) { return '' }
    $line = @(Get-Content $j | Where-Object { $_ -match "`tvh_guest_cart`t" }) | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line -split "`t")[-1]
}
# writes a jar holding a given cookie value (to replay an old or fake cookie)
function MakeJar($jar, $value) {
    [IO.File]::WriteAllText((Join-Path $tmp $jar), "localhost`tFALSE`t/api/v1/cart`tFALSE`t0`tvh_guest_cart`t$value`n")
}
function Login($email) {
    $r = Req 'POST' '/auth/login' $null $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Lines($cart) { return , @(@($cart.shops) | ForEach-Object { $_.items } | Where-Object { $_ }) }
function QtyOf($cart, $listingId) { return (@((Lines $cart) | Where-Object { $_.listingId -eq $listingId }) | Select-Object -First 1).quantity }

# ---- 1. bestListingId on product cards ----
$cards = @((Req 'GET' '/products?limit=48' $null $null $null).json.data)
Check 'product cards: 200 with items' ($cards.Count -gt 3) $true
Check 'every card has bestListingId' (@($cards | Where-Object { $null -eq $_.PSObject.Properties['bestListingId'] }).Count) 0
$buyable = @($cards | Where-Object { $_.bestListingId })
Check 'most cards have a bestListingId' ($buyable.Count -ge 3) $true
$p0 = $buyable[0]
$offers = @((Req 'GET' "/products/$($p0.slug)/listings" $null $null $null).json.data)
$cheapest = @($offers | Where-Object { $_.availability -ne 'OUT_OF_STOCK' -and $_.shop.verificationLevel -ne 'UNVERIFIED' } | Sort-Object price)[0]
Check 'bestListingId is the cheapest in-stock verified offer' ((@($offers | Where-Object { $_.id -eq $p0.bestListingId })[0].price) -eq $cheapest.price) $true
$shopId = $cheapest.shop.id
$shopCard = @((Req 'GET' "/products?shopId=$shopId&limit=48" $null $null $null).json.data | Where-Object { $_.bestListingId })[0]
$shopCardOffers = @((Req 'GET' "/products/$($shopCard.slug)/listings" $null $null $null).json.data)
Check 'shop page card points at that shop' ((@($shopCardOffers | Where-Object { $_.id -eq $shopCard.bestListingId })[0]).shop.id) $shopId
$L1 = $buyable[0].bestListingId; $L2 = $buyable[1].bestListingId; $L3 = $buyable[2].bestListingId

# ---- 2. guest without a cart ----
$r = Req 'GET' '/cart' 'a.jar' $null $null
Check 'guest GET /cart: 200' $r.status 200
Check 'guest GET /cart: empty' $r.json.data.totals.itemCount 0
Check 'guest GET /cart: no cookie set' ([string]::IsNullOrEmpty($r.setCookie)) $true
$r = Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = '00000000-0000-4000-8000-000000000000'; quantity = 1 }
Check 'guest add unknown listing: 404' $r.status 404
Check 'no cart (no cookie) for an invalid add' ([string]::IsNullOrEmpty($r.setCookie)) $true
Check 'guest add bad body: 400' (Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = 'x' }).status 400
Check 'still no cookie' (JarValue 'a.jar') ''

# ---- 3. first add creates the cart and the cookie ----
$r = Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = $L1; quantity = 9 }
Check 'guest add: 200' $r.status 200
Check 'cookie set' ($r.setCookie -ne '') $true
Check 'cookie HttpOnly' ($r.setCookie -match '; HttpOnly') $true
Check 'cookie SameSite=Lax' ($r.setCookie -match '; SameSite=Lax') $true
Check 'cookie Path=/api/v1/cart' ($r.setCookie -match '; Path=/api/v1/cart(;|$)') $true
Check 'cookie Max-Age 30 days' ($r.setCookie -match '; Max-Age=2592000(;|$)') $true
Check 'cookie not Secure in development' ($r.setCookie -match '; Secure') $false
$tokenA = JarValue 'a.jar'
Check 'cookie is a UUID' ($tokenA -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') $true
Check 'same response shape' ($null -ne $r.json.data.totals -and $null -ne $r.json.data.shops) $true
Check 'quantity 9' (QtyOf $r.json.data $L1) 9
Check 'price from the server' ((Lines $r.json.data)[0].unitPrice -gt 0) $true
$r = Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = $L2; quantity = 1 }
Check 'second add: no new cookie' ([string]::IsNullOrEmpty($r.setCookie)) $true
Check 'two lines' (Lines $r.json.data).Count 2
Check 'over 10 in one line: 400' (Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = $L1; quantity = 2 }).status 400
Check 'quantity 11 in the body: 400' (Req 'POST' '/cart/items' 'a.jar' $null @{ listingId = $L3; quantity = 11 }).status 400
$itemL2 = (@((Lines $r.json.data) | Where-Object { $_.listingId -eq $L2 })[0]).id
$r = Req 'PATCH' "/cart/items/$itemL2" 'a.jar' $null @{ quantity = 3 }
Check 'guest PATCH: 200' $r.status 200
Check 'PATCH applied' (QtyOf $r.json.data $L2) 3
Check 'guest PATCH bad id: 404' (Req 'PATCH' '/cart/items/abc' 'a.jar' $null @{ quantity = 1 }).status 404
$r = Req 'GET' '/cart' 'a.jar' $null $null
Check 'GET with the cookie shows the cart' $r.json.data.totals.itemCount 12

# ---- 4. isolation: other guests, fake cookies, no id from body/query/header ----
Check 'another guest sees an empty cart' (Req 'GET' '/cart' 'b.jar' $null $null).json.data.totals.itemCount 0
Check "another guest cannot PATCH A's item: 404" (Req 'PATCH' "/cart/items/$itemL2" 'b.jar' $null @{ quantity = 1 }).status 404
Check "another guest cannot DELETE A's item: 404" (Req 'DELETE' "/cart/items/$itemL2" 'b.jar' $null $null).status 404
Check "no cookie: cannot DELETE A's item: 404" (Req 'DELETE' "/cart/items/$itemL2" $null $null $null).status 404
Check 'cart id in the query is ignored' (Req 'GET' "/cart?cartId=$tokenA&guestCart=$tokenA" $null $null $null).json.data.totals.itemCount 0
Check 'cart id in the body is ignored' (Req 'DELETE' '/cart' $null $null @{ cartId = $tokenA; vh_guest_cart = $tokenA }).json.data.totals.itemCount 0
Check 'A is untouched' (Req 'GET' '/cart' 'a.jar' $null $null).json.data.totals.itemCount 12
MakeJar 'fake.jar' ([guid]::NewGuid().ToString())
Check 'unknown cookie: empty cart' (Req 'GET' '/cart' 'fake.jar' $null $null).json.data.totals.itemCount 0
MakeJar 'junk.jar' "not-a-uuid'; DROP TABLE"
Check 'malformed cookie: empty cart' (Req 'GET' '/cart' 'junk.jar' $null $null).json.data.totals.itemCount 0
$r = Req 'POST' '/cart/items' 'fake.jar' $null @{ listingId = $L3; quantity = 1 }
Check 'unknown cookie + add: new cart' $r.status 200
Check 'unknown cookie replaced' ((JarValue 'fake.jar') -ne '' -and $r.setCookie -ne '') $true

# ---- 5. guests cannot check out; a bad token is 401, not a silent guest cart ----
Check 'guest checkout: 401' (Req 'POST' '/checkout' 'a.jar' $null @{}).status 401
Check 'invalid token with a guest cookie: 401' (Req 'GET' '/cart' 'a.jar' 'not.a.token' $null).status 401
Check 'merge without login: 401' (Req 'POST' '/cart/merge' 'a.jar' $null $null).status 401

# ---- 6. merge ----
$cust = Login 'customer@vendorshub.test'
Req 'DELETE' '/cart' $null $cust $null | Out-Null
$r = Req 'POST' '/cart/items' $null $cust @{ listingId = $L1; quantity = 3 }
Check 'user cart has L1 x3' (QtyOf $r.json.data $L1) 3
$r = Req 'GET' '/cart' 'a.jar' $cust $null
Check 'logged in: own cart, not the guest cart' (QtyOf $r.json.data $L1) 3
Check 'logged in: guest lines not shown' ($null -eq (QtyOf $r.json.data $L2)) $true
$r = Req 'POST' '/cart/merge' 'a.jar' $cust $null
Check 'merge: 200' $r.status 200
Check 'same listing added and capped at 10' (QtyOf $r.json.data $L1) 10
Check 'new listing moved over' (QtyOf $r.json.data $L2) 3
Check 'cookie cleared' ($r.setCookie -match 'Expires=Thu, 01 Jan 1970') $true
Check 'jar has no cookie now' (JarValue 'a.jar') ''
$r = Req 'POST' '/cart/merge' 'a.jar' $cust $null
Check 'merge again: 200' $r.status 200
Check 'merge again: not doubled (L1)' (QtyOf $r.json.data $L1) 10
Check 'merge again: not doubled (L2)' (QtyOf $r.json.data $L2) 3
MakeJar 'old.jar' $tokenA
$r = Req 'POST' '/cart/merge' 'old.jar' $cust $null
Check 'replayed old cookie: nothing merged' (QtyOf $r.json.data $L2) 3
Check 'old cookie: guest cart is gone' (Req 'GET' '/cart' 'old.jar' $null $null).json.data.totals.itemCount 0
$r = Req 'POST' '/cart/merge' $null $cust $null
Check 'merge without cookie: 200 with the user cart' (QtyOf $r.json.data $L1) 10
# merge into a user without a cart yet
$owner = Login 'owner2@vendorshub.test'
Req 'POST' '/cart/items' 'c.jar' $null @{ listingId = $L3; quantity = 2 } | Out-Null
$r = Req 'POST' '/cart/merge' 'c.jar' $owner $null
Check 'merge into another user: L3 x2' (QtyOf $r.json.data $L3) 2
Req 'DELETE' '/cart' $null $owner $null | Out-Null
Req 'DELETE' '/cart' $null $cust $null | Out-Null

# ---- 7. cleanup job ----
Req 'POST' '/cart/items' 'd.jar' $null @{ listingId = $L1; quantity = 1 } | Out-Null
Check 'fresh guest cart has 1 item' (Req 'GET' '/cart' 'd.jar' $null $null).json.data.totals.itemCount 1
$purged = [int]([string](node --env-file=.env scripts/purge-guest-carts.mjs --backdate-all)).Trim()
Check 'stale guest carts deleted' ($purged -ge 1) $true
Check 'deleted guest cart reads as empty' (Req 'GET' '/cart' 'd.jar' $null $null).json.data.totals.itemCount 0
Check 'user carts are not touched' (Req 'POST' '/cart/items' $null $cust @{ listingId = $L1; quantity = 1 }).status 200
Req 'DELETE' '/cart' $null $cust $null | Out-Null

# ---- 8. guest write limit: 60 per minute per IP ----
$codes = @(1..61 | ForEach-Object { (Req 'DELETE' '/cart' 'e.jar' $null $null).status })
# (the writes earlier in this suite count in the same minute, so the 429 may come before write 61)
Check 'only 200 or 429' (@($codes | Where-Object { $_ -ne 200 -and $_ -ne 429 }).Count) 0
Check 'the limit is reached within 61 writes' $codes[60] 429
Check 'once limited, stays limited' (@($codes[([array]::IndexOf($codes, 429))..60] | Where-Object { $_ -ne 429 }).Count) 0
Check 'reads are not limited' (Req 'GET' '/cart' 'e.jar' $null $null).status 200
Check 'logged-in writes are not limited' (Req 'DELETE' '/cart' $null $cust $null).status 200

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
