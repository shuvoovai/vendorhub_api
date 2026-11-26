# test-deal-approval.ps1 (flash deals: a shop REQUESTS a deal, an admin APPROVES or REJECTS it; only
# approved deals change a price). Run on fresh seed data while the test API is running.
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
    if ($null -ne $body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)) }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json) } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what" -ForegroundColor Red; exit 1 } }
function Iso($date) { return $date.ToUniversalTime().ToString('o') }
function InFlash($id) { return @((Call 'GET' '/deals/flash?limit=20' $null $null).json.data | Where-Object { $_.dealId -eq $id }).Count -eq 1 }
function Review($id, $body) { return Call 'PATCH' "/admin/deals/$id/review" $admin $body }
function ShopDeal($id) { return @((Call 'GET' "/shops/$techId/deals" $owner $null).json.data | Where-Object { $_.id -eq $id })[0] }
function CartPrice($listingId) {
    Call 'DELETE' '/cart' $cust $null | Out-Null
    Call 'POST' '/cart/items' $cust @{ listingId = $listingId; quantity = 1 } | Out-Null
    return @(@((Call 'GET' '/cart' $cust $null).json.data.shops)[0].items)[0]
}
function Notes($title) { return @((Call 'GET' '/notifications?limit=50' $owner $null).json.data | Where-Object { $_.title -eq $title -and $_.data.dealId }) }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test' # TechZone owner

$techId = (Call 'GET' '/shops/techzone-electronics' $null $null).json.data.id
Need $techId 'TechZone not found'
$listings = @((Call 'GET' "/shops/$techId/listings?limit=50" $owner $null).json.data | Where-Object { $_.isActive -and $_.price -ge 1000 -and @($_.variants | Where-Object { $_.isActive }).Count -eq 0 })
Need ($listings.Count -ge 3) 'three active TechZone listings'
foreach ($l in $listings[0..2]) {
    Need ((Call 'PATCH' "/shops/$techId/listings/$($l.id)" $owner @{ availability = 'IN_STOCK'; stockQty = 20 }).status -eq 200) 'could not prepare a listing'
}
$listing = $listings[0]; $price = [int]$listing.price; $dealPrice = $price - 100
$second = $listings[1]
$third = $listings[2]
$now = Get-Date
$window = @{ startsAt = (Iso $now.AddMinutes(-1)); endsAt = (Iso $now.AddHours(3)) }

# ---- 1. a shop's deal is a request: PENDING, not live ----
$r = Call 'POST' "/shops/$techId/deals" $owner (@{ listingId = $listing.id; dealPrice = $dealPrice } + $window)
Check 'shop creates a deal: 201' $r.status 201
$dealId = $r.json.data.id
Check 'a new deal is PENDING' $r.json.data.status 'PENDING'
Check 'not reviewed yet' ($null -eq $r.json.data.reviewedAt) $true
Check 'no reject reason' ($null -eq $r.json.data.rejectReason) $true
Check 'a pending deal is not in /deals/flash' (InFlash $dealId) $false
$slug = $listing.product.slug
Check 'the product page shows no deal' ($null -eq (Call 'GET' "/products/$slug`?listingId=$($listing.id)" $null $null).json.data.selectedListing.deal) $true
$line = CartPrice $listing.id
Check 'the cart charges the normal price' $line.unitPrice $price
Check 'the cart applies no deal' $line.dealApplied $false
$co = Call 'POST' '/checkout' $cust @{ shops = @(@{ shopId = $techId; deliveryMethod = 'VENDOR_DELIVERY'; paymentMethod = 'CASH_ON_DELIVERY'; deliveryAddress = 'House 12, Road 5, Dhanmondi, Dhaka' }) }
Check 'checkout: 201' $co.status 201
Check 'checkout charges the normal price' (@(@($co.json.data.orders)[0].items)[0].unitPrice) $price
Check 'no deal units are counted' (ShopDeal $dealId).soldQty 0
Check 'the shop list shows the status' (ShopDeal $dealId).status 'PENDING'

# an admin using the shop route also only makes a request
$a = Call 'POST' "/shops/$techId/deals" $admin (@{ listingId = $second.id; dealPrice = [int]$second.price - 50 } + $window)
Check 'an admin creates through the shop route: 201' $a.status 201
Check 'that deal is PENDING too' $a.json.data.status 'PENDING'

# ---- 2. the admin queue ----
Check 'owner cannot list admin deals: 403' (Call 'GET' '/admin/deals?status=PENDING' $owner $null).status 403
Check 'bad status filter: 400' (Call 'GET' '/admin/deals?status=LIVE' $admin $null).status 400
$q = @((Call 'GET' '/admin/deals?status=PENDING&limit=100' $admin $null).json.data)
Check 'only pending deals in the queue' @($q | Where-Object { $_.status -ne 'PENDING' }).Count 0
Check 'oldest request first' ([array]::IndexOf(@($q | ForEach-Object { $_.id }), $dealId) -lt [array]::IndexOf(@($q | ForEach-Object { $_.id }), $a.json.data.id)) $true
$item = @($q | Where-Object { $_.id -eq $dealId })[0]
Check 'queue item has the listing price' $item.listing.price $price
Check 'queue item has the shop slug' $item.listing.shop.slug 'techzone-electronics'
Check 'queue item has the product image' ($null -ne $item.listing.product.PSObject.Properties['image']) $true

# ---- 3. review validation ----
Check 'reject without a reason: 400' (Review $dealId @{ decision = 'REJECT' }).status 400
Check 'reject with a 4-letter reason: 400' (Review $dealId @{ decision = 'REJECT'; reason = '  abcd  ' }).status 400
Check 'unknown decision: 400' (Review $dealId @{ decision = 'MAYBE' }).status 400
Check 'unknown field: 400' (Review $dealId @{ decision = 'APPROVE'; status = 'APPROVED' }).status 400
Check 'owner cannot review: 403' (Call 'PATCH' "/admin/deals/$dealId/review" $owner @{ decision = 'APPROVE' }).status 403
Check 'unknown deal: 404' (Review '00000000-0000-4000-8000-000000000000' @{ decision = 'APPROVE' }).status 404
Check 'bad id: 400' (Review 'x' @{ decision = 'APPROVE' }).status 400

# ---- 4. approve: live ----
$ap = Review $dealId @{ decision = 'APPROVE' }
Check 'admin approves: 200' $ap.status 200
Check 'status APPROVED' $ap.json.data.status 'APPROVED'
Check 'reviewedAt is set' ($null -ne $ap.json.data.reviewedAt) $true
Check 'the approved deal is in /deals/flash' (InFlash $dealId) $true
$line = CartPrice $listing.id
Check 'the cart charges the deal price' $line.unitPrice $dealPrice
Call 'DELETE' '/cart' $cust $null | Out-Null
Check 'review of an approved deal: 409' (Review $dealId @{ decision = 'REJECT'; reason = 'Too late now' }).status 409
Check 'the shop owner is told' (@(Notes 'Flash deal approved').Count -ge 1) $true

# ---- 5. pause / resume keeps the status; a new price needs a new review ----
Check 'shop pauses the deal: 200' (Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ isActive = $false }).status 200
Check 'paused deal stays APPROVED' (ShopDeal $dealId).status 'APPROVED'
Check 'a paused deal is not live' (InFlash $dealId) $false
Check 'shop resumes the deal: 200' (Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ isActive = $true }).status 200
Check 'resumed deal stays APPROVED' (ShopDeal $dealId).status 'APPROVED'
Check 'the same price again keeps APPROVED' (Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ dealPrice = $dealPrice }).json.data.status 'APPROVED'
$ed = Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ dealPrice = ($dealPrice - 10) }
Check 'shop changes the price: 200' $ed.status 200
Check 'a changed approved deal is PENDING again' $ed.json.data.status 'PENDING'
Check 'reviewedAt is cleared' ($null -eq $ed.json.data.reviewedAt) $true
Check 'the changed deal is not live' (InFlash $dealId) $false
Check 'the cart is back to the normal price' (CartPrice $listing.id).unitPrice $price
Call 'DELETE' '/cart' $cust $null | Out-Null

# ---- 6. reject ----
$reason = 'Price is not lower than last week'
$rj = Review $dealId @{ decision = 'REJECT'; reason = "  $reason  " }
Check 'admin rejects: 200' $rj.status 200
Check 'status REJECTED' $rj.json.data.status 'REJECTED'
Check 'the reason is stored (trimmed)' $rj.json.data.rejectReason $reason
Check 'the shop sees the reason' (ShopDeal $dealId).rejectReason $reason
Check 'a rejected deal is not live' (InFlash $dealId) $false
Check 'the shop owner is told why' (@(Notes "Flash deal rejected: $reason").Count -ge 1) $true
Check 'review of a rejected deal: 409' (Review $dealId @{ decision = 'APPROVE' }).status 409
Check 'pausing a rejected deal keeps REJECTED' (Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ isActive = $false }).json.data.status 'REJECTED'
Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ isActive = $true } | Out-Null
# a rejected deal does not block a new request in the same period
$n = Call 'POST' "/shops/$techId/deals" $owner (@{ listingId = $listing.id; dealPrice = $dealPrice - 20 } + $window)
Check 'a new request next to a rejected deal: 201' $n.status 201
Check 'the new request is PENDING' $n.json.data.status 'PENDING'
$fix = Call 'PATCH' "/shops/$techId/deals/$dealId" $owner @{ dealPrice = ($dealPrice - 30) }
Check 'editing the rejected deal into an overlap with a pending one: 409' $fix.status 409

# ---- 7. approve conflicts ----
Check 'approve the new request: 200' (Review $n.json.data.id @{ decision = 'APPROVE' }).status 200
# a paused request may overlap; approving it would make two live deals on one listing
$paused = Call 'POST' "/shops/$techId/deals" $owner (@{ listingId = $listing.id; dealPrice = $dealPrice - 40; isActive = $false } + $window)
Check 'a paused overlapping request: 201' $paused.status 201
Check 'approving an overlap with an approved deal: 409' (Review $paused.json.data.id @{ decision = 'APPROVE' }).status 409
Check 'it stays PENDING' (ShopDeal $paused.json.data.id).status 'PENDING'
$short = Call 'POST' "/shops/$techId/deals" $owner @{ listingId = $third.id; dealPrice = [int]$third.price - 50; startsAt = (Iso (Get-Date).AddMinutes(-1)); endsAt = (Iso (Get-Date).AddSeconds(3)) }
Check 'a short request: 201' $short.status 201
Start-Sleep -Seconds 4
Check 'approving a deal that has ended: 409' (Review $short.json.data.id @{ decision = 'APPROVE' }).status 409
Check 'rejecting it is still possible: 200' (Review $short.json.data.id @{ decision = 'REJECT'; reason = 'It has already ended' }).status 200

# ---- 8. lists and audit ----
Check 'status=APPROVED lists only approved' @((Call 'GET' '/admin/deals?status=APPROVED&limit=100' $admin $null).json.data | Where-Object { $_.status -ne 'APPROVED' }).Count 0
Check 'status=REJECTED has the rejected deal' @((Call 'GET' '/admin/deals?status=REJECTED&limit=100' $admin $null).json.data | Where-Object { $_.id -eq $dealId }).Count 1
Check 'no status lists every status' (@((Call 'GET' '/admin/deals?limit=100' $admin $null).json.data | ForEach-Object { $_.status } | Sort-Object -Unique).Count) 3
$logs = @((Call 'GET' '/admin/audit-logs?entityType=FlashDeal&limit=50' $admin $null).json.data | ForEach-Object { $_.action })
foreach ($x in @('deal.approved', 'deal.rejected')) { Check "audit log has $x" ($logs -contains $x) $true }

# cleanup: the admin removes every deal made here
foreach ($id in @($dealId, $a.json.data.id, $n.json.data.id, $paused.json.data.id, $short.json.data.id)) {
    Call 'DELETE' "/admin/deals/$id" $admin $null | Out-Null
}
Check 'cleanup: nothing of this suite is live' @((Call 'GET' '/deals/flash?limit=20' $null $null).json.data).Count 0

Write-Host ''
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
