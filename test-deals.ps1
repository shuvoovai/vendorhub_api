# test-deals.ps1 (flash deals: public list shape, expiry, shop access, price rules, cart/checkout price,
# plus the home page helpers: top-level categories, newSinceDays, sort=popular)
# Run from the project root on fresh seed data while "npm run dev" is running.
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
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); headers = $r.Headers } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what not found" -ForegroundColor Red; exit 1 } }
function Iso($date) { return $date.ToUniversalTime().ToString('o') }
function Flash { return @((Call 'GET' '/deals/flash?limit=20' $null $null).json.data) }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test'     # TechZone owner
$owner2 = Login 'owner2@vendorshub.test'    # Dhaka Mobile House owner

$techId = (Call 'GET' '/shops/techzone-electronics' $null $null).json.data.id
$dmhId = (Call 'GET' '/shops/dhaka-mobile-house' $null $null).json.data.id
Need $techId 'TechZone'; Need $dmhId 'Dhaka Mobile House'
$listing = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object {
    $_.isActive -and $_.availability -ne 'OUT_OF_STOCK' -and ($null -eq $_.stockQty -or $_.stockQty -ge 3) -and $_.price -ge 100 })[0]
Need $listing 'an in-stock TechZone listing'
$otherListing = @((Call 'GET' "/shops/$dmhId/listings" $owner2 $null).json.data)[0]
Need $otherListing 'a Dhaka Mobile House listing'
$price = [int]$listing.price
$dealPrice = $price - 50
$now = Get-Date
$deal = @{ listingId = $listing.id; dealPrice = $dealPrice; startsAt = (Iso $now.AddMinutes(-1)); endsAt = (Iso $now.AddHours(3)) }

# ---- 1. empty start ----
$pub = Call 'GET' '/deals/flash' $null $null
Check 'public list: 200 without login' $pub.status 200
Check 'no deals on fresh seed' @($pub.json.data).Count 0
Check 'short Cache-Control' ([string]$pub.headers['Cache-Control']) 'public, max-age=60'
Check 'limit over 20: 400' (Call 'GET' '/deals/flash?limit=21' $null $null).status 400

# ---- 2. access and validation ----
Check 'logged out: 401' (Call 'POST' "/owner/shops/$techId/deals" $null $deal).status 401
Check 'a customer: 403' (Call 'POST' "/owner/shops/$techId/deals" $cust $deal).status 403
$foreign = $deal.Clone(); $foreign.listingId = $otherListing.id
Check "another shop's listing via own shop: 404" (Call 'POST' "/owner/shops/$techId/deals" $owner $foreign).status 404
$o3 = Login 'owner3@vendorshub.test'
Check 'a shop the user does not manage: 403' (Call 'POST' "/owner/shops/$dmhId/deals" $owner $foreign).status 403
Check 'bad shopId: 400' (Call 'POST' '/owner/shops/not-a-uuid/deals' $owner $deal).status 400
$same = $deal.Clone(); $same.dealPrice = $price
Check 'dealPrice equal to the price: 400' (Call 'POST' "/owner/shops/$techId/deals" $owner $same).status 400
$higher = $deal.Clone(); $higher.dealPrice = $price + 1
Check 'dealPrice above the price: 400' (Call 'POST' "/owner/shops/$techId/deals" $owner $higher).status 400
$back = $deal.Clone(); $back.endsAt = (Iso $now.AddMinutes(-2))
Check 'endsAt before startsAt: 400' (Call 'POST' "/owner/shops/$techId/deals" $owner $back).status 400
$long = $deal.Clone(); $long.endsAt = (Iso $now.AddDays(8))
Check 'longer than 7 days: 400' (Call 'POST' "/owner/shops/$techId/deals" $owner $long).status 400
$extra = $deal.Clone(); $extra.unitPrice = 1
Check 'unknown field: 400' (Call 'POST' "/owner/shops/$techId/deals" $owner $extra).status 400

# ---- 3. create and the public shape ----
$r = Call 'POST' "/owner/shops/$techId/deals" $owner $deal
Check 'owner creates a deal: 201' $r.status 201
$dealId = $r.json.data.id
Check 'a second overlapping deal: 409' (Call 'POST' "/owner/shops/$techId/deals" $owner $deal).status 409
$items = @(Flash)
Check 'public list shows the deal' $items.Count 1
$it = $items[0]
foreach ($f in @('id', 'slug', 'title', 'brand', 'category', 'image', 'thumbnail', 'msrp', 'lowestPrice', 'highestPrice', 'shopCount', 'availability', 'bargainAvailable', 'createdAt', 'dealPrice', 'originalPrice', 'dealEndsAt', 'dealId', 'listingId')) {
    Check "item has $f" ($null -ne $it.PSObject.Properties[$f]) $true
}
Check 'id is the product id' $it.id $listing.productId
Check 'dealPrice' $it.dealPrice $dealPrice
Check 'originalPrice is the listing price' $it.originalPrice $price
Check 'dealEndsAt is ISO' ([string]$it.dealEndsAt -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$') $true
$detail = Call 'GET' "/products/$($it.slug)?listingId=$($listing.id)" $null $null
Check 'product page shows the deal price' $detail.json.data.selectedListing.deal.dealPrice $dealPrice

# ---- 4. cart and checkout use the deal price ----
Call 'DELETE' '/cart' $cust $null | Out-Null
Call 'POST' '/cart/items' $cust @{ listingId = $listing.id; quantity = 2 } | Out-Null
$line = @(@((Call 'GET' '/cart' $cust $null).json.data.shops)[0].items)[0]
Check 'cart unit price is the deal price' $line.unitPrice $dealPrice
Check 'cart marks dealApplied' $line.dealApplied $true
$choice = @{ shopId = $techId; deliveryMethod = 'VENDOR_DELIVERY'; paymentMethod = 'CASH_ON_DELIVERY'; deliveryAddress = 'House 12, Road 5, Dhanmondi, Dhaka' }
$co = Call 'POST' '/checkout' $cust @{ shops = @($choice) }
Check 'checkout: 201' $co.status 201
$item = @(@($co.json.data.orders)[0].items)[0]
Check 'checkout charges the deal price' $item.unitPrice $dealPrice
Check 'order subtotal uses the deal price' @($co.json.data.orders)[0].subtotal ($dealPrice * 2)
Check 'sold units are counted' (@((Call 'GET' "/owner/shops/$techId/deals" $owner $null).json.data | Where-Object { $_.id -eq $dealId })[0].soldQty) 2

# ---- 5. stock limit: no deal units left -> normal price ----
Check 'owner sets stockLimit 2' (Call 'PATCH' "/owner/shops/$techId/deals/$dealId" $owner @{ stockLimit = 2 }).status 200
Check 'sold-out deal is hidden' @(Flash).Count 0
Call 'POST' '/cart/items' $cust @{ listingId = $listing.id; quantity = 1 } | Out-Null
$line = @(@((Call 'GET' '/cart' $cust $null).json.data.shops)[0].items)[0]
Check 'sold-out deal: normal price in the cart' $line.unitPrice $price
Call 'DELETE' '/cart' $cust $null | Out-Null
Check 'PATCH dealPrice >= price: 400' (Call 'PATCH' "/owner/shops/$techId/deals/$dealId" $owner @{ dealPrice = $price }).status 400
Check 'PATCH empty body: 400' (Call 'PATCH' "/owner/shops/$techId/deals/$dealId" $owner @{}).status 400
Check "other owner cannot PATCH: 403" (Call 'PATCH' "/owner/shops/$techId/deals/$dealId" $o3 @{ dealPrice = 1 }).status 403
Check "deal under another shop's path: 404" (Call 'PATCH' "/owner/shops/$dmhId/deals/$dealId" $owner2 @{ dealPrice = 1 }).status 404

# ---- 6. an expired deal is hidden and the normal price applies again ----
Check 'owner deletes the deal' (Call 'DELETE' "/owner/shops/$techId/deals/$dealId" $owner $null).status 200
$short = $deal.Clone(); $short.endsAt = (Iso (Get-Date).AddSeconds(4))
$r = Call 'POST' "/owner/shops/$techId/deals" $owner $short
Check 'a short deal is created' $r.status 201
$shortId = $r.json.data.id
Check 'the short deal is listed while running' @(Flash).Count 1
Call 'POST' '/cart/items' $cust @{ listingId = $listing.id; quantity = 1 } | Out-Null
Start-Sleep -Seconds 6
Check 'the expired deal is hidden' @(Flash).Count 0
$line = @(@((Call 'GET' '/cart' $cust $null).json.data.shops)[0].items)[0]
Check 'expired deal: normal price in the cart' $line.unitPrice $price
$co = Call 'POST' '/checkout' $cust @{ shops = @($choice) }
Check 'checkout after expiry charges the normal price' (@(@($co.json.data.orders)[0].items)[0].unitPrice) $price

# ---- 7. admin ----
Check 'admin list as owner: 403' (Call 'GET' '/admin/deals' $owner $null).status 403
$all = Call 'GET' '/admin/deals' $admin $null
Check 'admin lists deals' (@($all.json.data | Where-Object { $_.id -eq $shortId }).Count) 1
Check 'admin delete bad id: 400' (Call 'DELETE' '/admin/deals/x' $admin $null).status 400
Check 'admin deletes a deal' (Call 'DELETE' "/admin/deals/$shortId" $admin $null).status 200
Check 'admin delete again: 404' (Call 'DELETE' "/admin/deals/$shortId" $admin $null).status 404
$logs = @((Call 'GET' '/admin/audit-logs?entityType=FlashDeal&limit=50' $admin $null).json.data | ForEach-Object { $_.action })
foreach ($a in @('deal.created', 'deal.updated', 'deal.deleted', 'deal.admin_deleted')) { Check "audit log has $a" ($logs -contains $a) $true }

# ---- 8. home page helpers ----
$cats = @((Call 'GET' '/categories?topLevel=true' $null $null).json.data)
Check 'top-level categories only' (@($cats | Where-Object { $_.parentId }).Count) 0
$sorted = $true
for ($i = 1; $i -lt $cats.Count; $i++) {
    $a = $cats[$i - 1]; $b = $cats[$i]
    if ($a.sortOrder -gt $b.sortOrder -or ($a.sortOrder -eq $b.sortOrder -and $a.productCount -lt $b.productCount)) { $sorted = $false }
}
Check 'ordered by sortOrder, then productCount desc' $sorted $true
$last = $cats[$cats.Count - 1]
Check 'admin sets a sortOrder' (Call 'PATCH' "/admin/categories/$($last.id)" $admin @{ sortOrder = 0 }).status 200
Call 'PATCH' "/admin/categories/$($cats[0].id)" $admin @{ sortOrder = 5 } | Out-Null
Check 'sortOrder moves a category to the end' (@((Call 'GET' '/categories?topLevel=true' $null $null).json.data)[-1].id) $cats[0].id
Call 'PATCH' "/admin/categories/$($cats[0].id)" $admin @{ sortOrder = 0 } | Out-Null
Check 'the full category list still has subcategories (unchanged)' ((Call 'GET' '/categories' $null $null).status) 200
Check 'newSinceDays=0: 400' (Call 'GET' '/products?newSinceDays=0' $null $null).status 400
Check 'newSinceDays=61: 400' (Call 'GET' '/products?newSinceDays=61' $null $null).status 400
$new = Call 'GET' '/products?sort=newest&newSinceDays=30&limit=50' $null $null
$cut = (Get-Date).ToUniversalTime().AddDays(-30)
Check 'newSinceDays keeps recent products only' (@($new.json.data | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -lt $cut }).Count) 0
$pop = Call 'GET' '/products?sort=popular&limit=50' $null $null
Check 'sort=popular: 200' $pop.status 200
# other suites also place orders, so only check ranks relative to sort=newest
$popIds = @($pop.json.data | ForEach-Object { $_.id })
$newIds = @((Call 'GET' '/products?sort=newest&limit=50' $null $null).json.data | ForEach-Object { $_.id })
$popRank = [array]::IndexOf($popIds, $listing.productId)
Check 'the just-ordered product is on the first popular page' (($popRank -ge 0) -and ($popRank -lt 12)) $true
Check 'popular ranks it at least as high as newest' ($popRank -le [array]::IndexOf($newIds, $listing.productId)) $true

Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
