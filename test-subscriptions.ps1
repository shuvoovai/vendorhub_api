# test-subscriptions.ps1 (vendor plans FREE / PRO: a shop owner pays by bKash / Nagad and requests Pro, an admin
# approves or rejects it; FREE shops have a listing limit and no flash deals). Run on fresh seed data while the
# test API is running.
$base = 'http://localhost:4000/api/v1'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
# Error answers keep their JSON too (details.code), read from ErrorDetails.
function Call($method, $path, $token, $body) {
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true }
    if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)) }
    try {
        $r = Invoke-WebRequest @p
        $j = $null
        if ($r.Content) { $j = $r.Content | ConvertFrom-Json }
        return @{ status = [int]$r.StatusCode; json = $j; raw = $r.Content }
    }
    catch {
        if ($_.Exception.Response) {
            $raw = $_.ErrorDetails.Message
            $j = $null
            if ($raw) { try { $j = $raw | ConvertFrom-Json } catch { $j = $null } }
            return @{ status = [int]$_.Exception.Response.StatusCode; json = $j; raw = $raw }
        }
        return @{ status = 0; json = $null; raw = $null }
    }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what" -ForegroundColor Red; exit 1 } }
# A JSON date (string, or DateTime in newer PowerShell) as a DateTimeOffset in UTC
function AsDate($v) {
    if ($v -is [DateTime]) { return [DateTimeOffset]$v.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
# Calendar months in Asia/Dhaka (UTC+6, no daylight saving); .NET AddMonths clamps the day like the API
function AddMonthsDhaka($v, $months) { return (AsDate $v).ToOffset([TimeSpan]::FromHours(6)).AddMonths($months).ToUniversalTime() }
function Ms($d) { return $d.ToUnixTimeMilliseconds() }
function NewTrx() { $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; return 'S' + (-join (1..9 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })) }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner1 = Login 'owner1@vendorshub.test' # TechZone owner (a demo shop: Pro in the seed)
$stamp = Get-Date -Format 'yyyyMMddHHmmss'

# a new shop owner with two new (FREE) shops, and a new user as staff of the first one
$email = "subowner$stamp@vendorshub.test"
Need ((Call 'POST' '/auth/register' $null @{ name = 'Sub Owner'; email = $email; password = 'Password123!'; role = 'SHOP_OWNER' }).status -eq 201) 'registering a shop owner'
$owner = Login $email
$prefix = "SubTest$stamp"
$shopA = (Call 'POST' '/shops' $owner @{ name = "$prefix Beta"; addressLine = 'Level 2, Shop 8, Bashundhara City, Dhaka'; phone = '01712345678' }).json.data
$shopB = (Call 'POST' '/shops' $owner @{ name = "$prefix Alpha"; addressLine = 'Level 2, Shop 9, Bashundhara City, Dhaka'; phone = '01712345679' }).json.data
Need $shopA.id 'creating shop A'
Need $shopB.id 'creating shop B'
$sid = $shopA.id
$staffEmail = "substaff$stamp@vendorshub.test"
Need ((Call 'POST' '/auth/register' $null @{ name = 'Sub Staff'; email = $staffEmail; password = 'Password123!' }).status -eq 201) 'registering the staff user'
Need ((Call 'POST' "/shops/$sid/staff" $owner @{ email = $staffEmail }).status -eq 201) 'adding staff'
$staff = Login $staffEmail # after the role upgrade

# ---- 1. plans (public) ----
$pl = Call 'GET' '/subscription-plans' $null $null
Check 'plans: 200 without login' $pl.status 200
$free = @($pl.json.data | Where-Object { $_.code -eq 'FREE' })[0]
$pro = @($pl.json.data | Where-Object { $_.code -eq 'PRO' })[0]
Check 'two plans' @($pl.json.data).Count 2
Check 'FREE: 20 listings' $free.maxListings 20
Check 'FREE: no flash deals' $free.flashDeals $false
Check 'FREE: no badge' $free.featuredBadge $false
Check 'FREE: no prices' @($free.prices).Count 0
Check 'PRO: unlimited listings (null)' ($null -eq $pro.maxListings) $true
Check 'PRO: flash deals' $pro.flashDeals $true
Check 'PRO: badge' $pro.featuredBadge $true
Check 'PRO: the four prices' ((@($pro.prices) | ForEach-Object { "$($_.months)=$($_.amount)" }) -join ',') '1=500,3=1350,6=2500,12=4800'

# ---- 2. owner-only access ----
$s = Call 'GET' "/shops/$sid/subscription" $owner $null
Check 'owner reads the subscription: 200' $s.status 200
Check 'a new shop is FREE' $s.json.data.plan 'FREE'
Check 'FREE has no period end' ($null -eq $s.json.data.currentPeriodEnd) $true
Check 'no listings used yet' $s.json.data.listingsUsed 0
Check 'no pending request' ($null -eq $s.json.data.pendingRequest) $true
Check 'no rejected request' ($null -eq $s.json.data.lastRejected) $true
Check 'staff: 403' (Call 'GET' "/shops/$sid/subscription" $staff $null).status 403
Check 'another shop owner: 404' (Call 'GET' "/shops/$sid/subscription" $owner1 $null).status 404
Check 'a customer: 404' (Call 'GET' "/shops/$sid/subscription" $cust $null).status 404
Check 'no login: 401' (Call 'GET' "/shops/$sid/subscription" $null $null).status 401
Check 'bad shop id: 400' (Call 'GET' '/shops/x/subscription' $owner $null).status 400
Check 'unknown shop: 404' (Call 'GET' '/shops/00000000-0000-4000-8000-000000000000/subscription' $owner $null).status 404
Check 'the TechZone owner sees a Pro demo shop' (Call 'GET' "/shops/$((Call 'GET' '/shops/techzone-electronics' $null $null).json.data.id)/subscription" $owner1 $null).json.data.plan 'PRO'

# ---- 3. FREE: listing limit and no flash deals ----
$products = @((Call 'GET' '/products?limit=50' $null $null).json.data)
Need ($products.Count -ge 22) '22 products'
$lst = @{}
$ok = 0
for ($i = 0; $i -lt 20; $i++) {
    $r = Call 'POST' "/shops/$sid/listings" $owner @{ productId = $products[$i].id; price = 5000; stockQty = 10 }
    if ($r.status -eq 201) { $ok++; $lst[$i] = $r.json.data.id }
}
Check 'a FREE shop adds 20 listings' $ok 20
Check 'listingsUsed is 20' (Call 'GET' "/shops/$sid/subscription" $owner $null).json.data.listingsUsed 20
$over = Call 'POST' "/shops/$sid/listings" $owner @{ productId = $products[20].id; price = 5000; stockQty = 10 }
Check 'the 21st listing: 403' $over.status 403
Check 'code PLAN_LIMIT' $over.json.error.details.code 'PLAN_LIMIT'
Check 'staff hits the same limit: 403' (Call 'POST' "/shops/$sid/listings" $staff @{ productId = $products[20].id; price = 5000 }).status 403
Check 'editing an existing listing still works: 200' (Call 'PATCH' "/shops/$sid/listings/$($lst[1])" $owner @{ price = 4900 }).status 200
Check 'remove a listing: 200' (Call 'DELETE' "/shops/$sid/listings/$($lst[0])" $owner $null).status 200
Check 'then a new one fits: 201' (Call 'POST' "/shops/$sid/listings" $owner @{ productId = $products[20].id; price = 5000; stockQty = 10 }).status 201
$re = Call 'PATCH' "/shops/$sid/listings/$($lst[0])" $owner @{ isActive = $true }
Check 're-activating at the limit: 403' $re.status 403
Check 're-activating: code PLAN_LIMIT' $re.json.error.details.code 'PLAN_LIMIT'
Check 're-adding the removed product at the limit: 403' (Call 'POST' "/shops/$sid/listings" $owner @{ productId = $products[0].id; price = 5000 }).status 403
$now = Get-Date
$window = @{ startsAt = $now.AddMinutes(-1).ToUniversalTime().ToString('o'); endsAt = $now.AddHours(3).ToUniversalTime().ToString('o') }
$dr = Call 'POST' "/shops/$sid/deals" $owner (@{ listingId = $lst[1]; dealPrice = 4000 } + $window)
Check 'a FREE shop requests a flash deal: 403' $dr.status 403
Check 'code PLAN_REQUIRED' $dr.json.error.details.code 'PLAN_REQUIRED'
Check 'an admin through the shop route: 403 too' (Call 'POST' "/shops/$sid/deals" $admin (@{ listingId = $lst[1]; dealPrice = 4000 } + $window)).status 403

# ---- 4. a request: validation, one pending at a time, withdraw ----
$path = "/shops/$sid/subscription/requests"
$trx1 = NewTrx
$good = @{ plan = 'PRO'; months = 1; method = 'NAGAD'; walletNumber = '01811223344'; transactionId = $trx1.ToLower() }
Check 'staff cannot request: 403' (Call 'POST' $path $staff $good).status 403
Check 'another shop owner: 404' (Call 'POST' $path $owner1 $good).status 404
$two = $good.Clone(); $two.months = 2
Check 'months not sold (2): 400' (Call 'POST' $path $owner $two).status 400
Check 'an amount from the client: 400' (Call 'POST' $path $owner (@{ amount = 1 } + $good)).status 400
Check 'plan FREE: 400' (Call 'POST' $path $owner (@{ plan = 'FREE'; months = 1; method = 'NAGAD'; walletNumber = '01811223344'; transactionId = $trx1 })).status 400
Check 'bad wallet number: 400' (Call 'POST' $path $owner (@{ plan = 'PRO'; months = 1; method = 'NAGAD'; walletNumber = '0181122334'; transactionId = $trx1 })).status 400
$badTrx = Call 'POST' $path $owner (@{ plan = 'PRO'; months = 1; method = 'BKASH'; walletNumber = '01811223344'; transactionId = 'AB-12' })
Check 'bad transaction ID: 400' $badTrx.status 400
Check 'the error does not echo it' ($badTrx.raw -like '*AB-12*') $false
$r1 = Call 'POST' $path $owner $good
Check 'owner requests Pro: 201' $r1.status 201
Check 'status PENDING' $r1.json.data.status 'PENDING'
Check 'amount from the config (1 month = 500)' $r1.json.data.amount 500
Check 'the TrxID is stored uppercase' $r1.json.data.transactionId $trx1
Check 'the owner sees the wallet number' $r1.json.data.walletNumber '01811223344'
Check 'not reviewed yet' ($null -eq $r1.json.data.reviewedAt) $true
$second = Call 'POST' $path $owner (@{ plan = 'PRO'; months = 3; method = 'BKASH'; walletNumber = '01711223344'; transactionId = (NewTrx) })
Check 'a second pending request: 409' $second.status 409
Check 'code REQUEST_PENDING' $second.json.error.details.code 'REQUEST_PENDING'
Check 'the pending request is shown' (Call 'GET' "/shops/$sid/subscription" $owner $null).json.data.pendingRequest.id $r1.json.data.id
Check 'staff cannot withdraw: 403' (Call 'DELETE' "$path/$($r1.json.data.id)" $staff $null).status 403
Check 'another owner cannot withdraw it: 404' (Call 'DELETE' "$path/$($r1.json.data.id)" $owner1 $null).status 404
Check 'withdraw through another shop of the owner: 404' (Call 'DELETE' "/shops/$($shopB.id)/subscription/requests/$($r1.json.data.id)" $owner $null).status 404
Check 'owner withdraws: 204' (Call 'DELETE' "$path/$($r1.json.data.id)" $owner $null).status 204
Check 'withdrawn again: 404' (Call 'DELETE' "$path/$($r1.json.data.id)" $owner $null).status 404
Check 'nothing pending after the withdrawal' ($null -eq (Call 'GET' "/shops/$sid/subscription" $owner $null).json.data.pendingRequest) $true

# ---- 5. admin queue and approve (FREE -> PRO from now) ----
$trx2 = NewTrx
$r2 = Call 'POST' $path $owner @{ plan = 'PRO'; months = 3; method = 'BKASH'; walletNumber = '01711223344'; transactionId = $trx2 }
Check 'a new request (3 months): 201' $r2.status 201
Check 'amount 1350' $r2.json.data.amount 1350
$id2 = $r2.json.data.id
Check 'owner cannot list admin requests: 403' (Call 'GET' '/admin/subscriptions/requests?status=PENDING' $owner $null).status 403
Check 'bad status filter: 400' (Call 'GET' '/admin/subscriptions/requests?status=PAID' $admin $null).status 400
$q = Call 'GET' '/admin/subscriptions/requests?status=PENDING&limit=100' $admin $null
Check 'admin lists pending: 200' $q.status 200
Check 'only pending requests' @($q.json.data | Where-Object { $_.status -ne 'PENDING' }).Count 0
$item = @($q.json.data | Where-Object { $_.id -eq $id2 })[0]
Check 'the queue item has the shop slug' $item.shop.slug $shopA.slug
Check 'the admin sees the TrxID' $item.transactionId $trx2
Check 'pagination is sent' ($null -ne $q.json.meta.pagination.total) $true
Check 'owner cannot review: 403' (Call 'PATCH' "/admin/subscriptions/requests/$id2/review" $owner @{ decision = 'APPROVE' }).status 403
Check 'unknown decision: 400' (Call 'PATCH' "/admin/subscriptions/requests/$id2/review" $admin @{ decision = 'MAYBE' }).status 400
Check 'APPROVE with a reason: 400' (Call 'PATCH' "/admin/subscriptions/requests/$id2/review" $admin @{ decision = 'APPROVE'; reason = 'fine' }).status 400
Check 'unknown request: 404' (Call 'PATCH' '/admin/subscriptions/requests/00000000-0000-4000-8000-000000000000/review' $admin @{ decision = 'APPROVE' }).status 404
Check 'bad id: 400' (Call 'PATCH' '/admin/subscriptions/requests/x/review' $admin @{ decision = 'APPROVE' }).status 400
$ap = Call 'PATCH' "/admin/subscriptions/requests/$id2/review" $admin @{ decision = 'APPROVE' }
Check 'admin approves: 200' $ap.status 200
Check 'status APPROVED' $ap.json.data.status 'APPROVED'
Check 'reviewedAt is set' ($null -ne $ap.json.data.reviewedAt) $true
Check 'review again: 409' (Call 'PATCH' "/admin/subscriptions/requests/$id2/review" $admin @{ decision = 'REJECT'; reason = 'Too late now' }).status 409
Check 'withdraw an approved request: 409' (Call 'DELETE' "$path/$id2" $owner $null).status 409
$s = Call 'GET' "/shops/$sid/subscription" $owner $null
Check 'the shop is PRO' $s.json.data.plan 'PRO'
$end1 = AsDate $s.json.data.currentPeriodEnd
Check 'Pro ends 3 calendar months after the approval (Dhaka)' (Ms $end1) (Ms (AddMonthsDhaka $ap.json.data.reviewedAt 3))

# ---- 6. Pro: no listing limit, flash deals, badge, search order ----
Check 'Pro: re-activating works: 200' (Call 'PATCH' "/shops/$sid/listings/$($lst[0])" $owner @{ isActive = $true }).status 200
Check 'Pro: a 22nd listing: 201' (Call 'POST' "/shops/$sid/listings" $owner @{ productId = $products[21].id; price = 5000; stockQty = 10 }).status 201
Check 'listingsUsed is 22' (Call 'GET' "/shops/$sid/subscription" $owner $null).json.data.listingsUsed 22
$deal = Call 'POST' "/shops/$sid/deals" $owner (@{ listingId = $lst[1]; dealPrice = 4000 } + $window)
Check 'Pro: a flash deal request: 201' $deal.status 201
if ($deal.json.data.id) { Call 'DELETE' "/admin/deals/$($deal.json.data.id)" $admin $null | Out-Null }
$front = Call 'GET' "/shops/$($shopA.slug)" $null $null
Check 'storefront isPro' $front.json.data.isPro $true
Check 'storefront has no proUntil' ($null -eq $front.json.data.PSObject.Properties['proUntil']) $true
Check 'a FREE storefront: isPro false' (Call 'GET' "/shops/$($shopB.slug)" $null $null).json.data.isPro $false
Check 'a demo shop is Pro' (Call 'GET' '/shops/techzone-electronics' $null $null).json.data.isPro $true
$found = @((Call 'GET' "/shops?q=$prefix" $null $null).json.data)
Check 'search finds both new shops' $found.Count 2
Check 'the Pro shop comes first (Beta before Alpha)' $found[0].slug $shopA.slug
Check 'search card isPro' $found[0].isPro $true
Check 'search card FREE: isPro false' $found[1].isPro $false
$pp = (Call 'GET' "/products/$($products[1].slug)?listingId=$($lst[1])" $null $null).json.data
Check 'product page: the selected shop isPro' $pp.selectedListing.shop.isPro $true
Check 'product page: no proUntil' ($null -eq $pp.selectedListing.shop.PSObject.Properties['proUntil']) $true

# ---- 7. a TrxID pays once ----
$dup = Call 'POST' $path $owner @{ plan = 'PRO'; months = 1; method = 'BKASH'; walletNumber = '01711223344'; transactionId = $trx2.ToLower() }
Check 'a used TrxID (any case): 409' $dup.status 409
Check 'code TRANSACTION_USED' $dup.json.error.details.code 'TRANSACTION_USED'
Check 'used by another shop: 409' (Call 'POST' "/shops/$($shopB.id)/subscription/requests" $owner @{ plan = 'PRO'; months = 1; method = 'BKASH'; walletNumber = '01711223344'; transactionId = $trx2 }).status 409
# an order's bKash payment with its own TrxID
$p = Call 'GET' '/products/galaxy-a55-5g-8-128gb' $null $null
$tl = @(@($p.json.data.selectedListing) + @($p.json.data.otherListings) | Where-Object { $_.shop.slug -eq 'techzone-electronics' })[0]
Need $tl 'TechZone listing'
Need ((Call 'PATCH' "/shops/$($tl.shop.id)/listings/$($tl.id)" $owner1 @{ availability = 'IN_STOCK'; stockQty = 20 }).status -eq 200) 'preparing the TechZone listing'
Call 'DELETE' '/cart' $cust $null | Out-Null
Call 'POST' '/cart/items' $cust @{ listingId = $tl.id; quantity = 1 } | Out-Null
$orderTrx = NewTrx
$co = Call 'POST' '/checkout' $cust @{ shops = @(@{ shopId = $tl.shop.id; deliveryMethod = 'STORE_PICKUP'; paymentMethod = 'BKASH'; paymentDetails = @{ walletNumber = '01811223344'; transactionId = $orderTrx } }) }
Check 'an order paid by bKash: 201' $co.status 201
Check 'a TrxID used by an order: 409' (Call 'POST' $path $owner @{ plan = 'PRO'; months = 1; method = 'BKASH'; walletNumber = '01811223344'; transactionId = $orderTrx }).status 409

# ---- 8. reject with a reason ----
$r3 = Call 'POST' $path $owner @{ plan = 'PRO'; months = 6; method = 'NAGAD'; walletNumber = '01811223344'; transactionId = (NewTrx) }
Check 'a request while Pro (6 months): 201' $r3.status 201
Check 'amount 2500' $r3.json.data.amount 2500
$id3 = $r3.json.data.id
Check 'reject without a reason: 400' (Call 'PATCH' "/admin/subscriptions/requests/$id3/review" $admin @{ decision = 'REJECT' }).status 400
Check 'reject with a 2-letter reason: 400' (Call 'PATCH' "/admin/subscriptions/requests/$id3/review" $admin @{ decision = 'REJECT'; reason = '  ab  ' }).status 400
$reason = 'No payment with this TrxID'
$rj = Call 'PATCH' "/admin/subscriptions/requests/$id3/review" $admin @{ decision = 'REJECT'; reason = "  $reason  " }
Check 'admin rejects: 200' $rj.status 200
Check 'status REJECTED' $rj.json.data.status 'REJECTED'
Check 'the reason is stored (trimmed)' $rj.json.data.rejectReason $reason
$s = Call 'GET' "/shops/$sid/subscription" $owner $null
Check 'lastRejected is the rejected request' $s.json.data.lastRejected.id $id3
Check 'lastRejected has the reason' $s.json.data.lastRejected.rejectReason $reason
Check 'still PRO after a rejection' $s.json.data.plan 'PRO'
Check 'the Pro end did not change' (Ms (AsDate $s.json.data.currentPeriodEnd)) (Ms $end1)
Check 'status=REJECTED lists it' @((Call 'GET' '/admin/subscriptions/requests?status=REJECTED&limit=100' $admin $null).json.data | Where-Object { $_.id -eq $id3 }).Count 1

# ---- 9. approve while already Pro: extends from the current end ----
$r4 = Call 'POST' $path $owner @{ plan = 'PRO'; months = 1; method = 'BKASH'; walletNumber = '01711223344'; transactionId = (NewTrx) }
Check 'another request (1 month): 201' $r4.status 201
Check 'approve while Pro: 200' (Call 'PATCH' "/admin/subscriptions/requests/$($r4.json.data.id)/review" $admin @{ decision = 'APPROVE' }).status 200
$s = Call 'GET' "/shops/$sid/subscription" $owner $null
Check 'Pro is extended by 1 month from the old end' (Ms (AsDate $s.json.data.currentPeriodEnd)) (Ms (AddMonthsDhaka $end1.ToString('o') 1))
Check 'an approval after the rejection hides lastRejected' ($null -eq $s.json.data.lastRejected) $true
Check 'no request pending' ($null -eq $s.json.data.pendingRequest) $true

# ---- 10. notifications and audit ----
$notes = @((Call 'GET' '/notifications?limit=50' $owner $null).json.data)
Check 'the owner is told about the approval' (@($notes | Where-Object { $_.title -eq 'Pro plan activated' -and $_.data.requestId -eq $id2 }).Count) 1
Check 'the owner is told the reason' (@($notes | Where-Object { $_.title -eq "Pro request rejected: $reason" }).Count) 1
Check 'no TrxID in the notifications' (@($notes | Where-Object { ($_ | ConvertTo-Json -Depth 5) -like "*$trx2*" }).Count) 0
$adminNotes = @((Call 'GET' '/notifications?limit=50' $admin $null).json.data | Where-Object { $_.data.requestId -eq $id2 })
Check 'admins are told about a new request' $adminNotes.Count 1
$logs = @((Call 'GET' '/admin/audit-logs?entityType=SubscriptionRequest&limit=50' $admin $null).json.data)
foreach ($x in @('subscription.requested', 'subscription.withdrawn', 'subscription.approved', 'subscription.rejected')) {
    Check "audit log has $x" (@($logs | Where-Object { $_.action -eq $x }).Count -ge 1) $true
}
Check 'no TrxID in the audit log' (@($logs | Where-Object { ($_ | ConvertTo-Json -Depth 6) -like "*$trx2*" }).Count) 0

Call 'DELETE' '/cart' $cust $null | Out-Null

Write-Host ''
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
