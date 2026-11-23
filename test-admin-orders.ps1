# test-admin-orders.ps1 (bKash payment method + admin orders section)
# Run from the project root while "npm run dev" is running.
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

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test'

$p = Call 'GET' '/products/galaxy-a55-5g-8-128gb' $null $null
$all = @($p.json.data.selectedListing) + @($p.json.data.otherListings)
$listing = @($all | Where-Object { $_.shop.slug -eq 'techzone-electronics' })[0]
Need $listing 'TechZone listing not found'
$shopId = $listing.shop.id
Need ((Call 'PATCH' "/shops/$shopId/listings/$($listing.id)" $owner @{ availability = 'IN_STOCK'; stockQty = 20 }).status -eq 200) 'could not prepare the listing'

function PlaceOrder($delivery, $payment) {
    Call 'DELETE' '/cart' $cust $null | Out-Null
    Call 'POST' '/cart/items' $cust @{ listingId = $listing.id; quantity = 1 } | Out-Null
    $c = @{ shopId = $shopId; deliveryMethod = $delivery; paymentMethod = $payment }
    if ($delivery -eq 'VENDOR_DELIVERY') { $c.deliveryAddress = 'House 12, Road 5, Dhanmondi, Dhaka' }
    return Call 'POST' '/checkout' $cust @{ shops = @($c) }
}
function Stock { return @((Call 'GET' "/shops/$shopId/listings?limit=50" $owner $null).json.data | Where-Object { $_.id -eq $listing.id })[0].stockQty }

# ---- 1. bKash checkout ----
$r = PlaceOrder 'STORE_PICKUP' 'BKASH'
Check 'bKash with store pickup: 201' $r.status 201
$pick = @($r.json.data.orders)[0]
Check 'bKash order is PLACED' $pick.status 'PLACED'
Check 'bKash order payment PENDING' $pick.paymentStatus 'PENDING'
Check 'bKash payment method saved' $pick.paymentMethod 'BKASH'
$r = PlaceOrder 'VENDOR_DELIVERY' 'BKASH'
Check 'bKash with delivery: 201' $r.status 201
$del = @($r.json.data.orders)[0]
Check 'unknown payment method: 400' (PlaceOrder 'STORE_PICKUP' 'NAGAD').status 400

# ---- 2. the vendor may confirm without waiting for the payment ----
Check 'vendor confirms bKash pickup: 200' (Call 'POST' "/shops/$shopId/orders/$($pick.id)/status" $owner @{ status = 'CONFIRMED' }).status 200
Check 'vendor confirms bKash delivery: 200' (Call 'POST' "/shops/$shopId/orders/$($del.id)/status" $owner @{ status = 'CONFIRMED' }).status 200

# ---- 3. access and list ----
Check 'no token: 401' (Call 'GET' '/admin/orders' $null $null).status 401
Check 'customer: 403' (Call 'GET' '/admin/orders' $cust $null).status 403
Check 'owner: 403' (Call 'PATCH' "/admin/orders/$($pick.id)" $owner @{ status = 'COMPLETED' }).status 403
$l = Call 'GET' '/admin/orders?limit=50' $admin $null
Check 'admin list: 200' $l.status 200
$rows = @($l.json.data)
Check 'no PLACED orders in the list' @($rows | Where-Object { $_.status -eq 'PLACED' }).Count 0
$row = @($rows | Where-Object { $_.id -eq $pick.id })[0]
Check 'the confirmed order is listed' ($null -ne $row) $true
Check 'item has customer.name' ($row.customer.name -ne $null) $true
Check 'item has customer.id' ($row.customer.id -ne $null) $true
Check 'item has shop' ($row.shop.id) $shopId
Check 'meta.pagination present' ($l.json.meta.pagination.total -ge 2) $true
Check 'status filter' (@((Call 'GET' '/admin/orders?status=CONFIRMED&limit=50' $admin $null).json.data | Where-Object { $_.status -ne 'CONFIRMED' }).Count) 0
Check 'bad status filter: 400' (Call 'GET' '/admin/orders?status=PLACED' $admin $null).status 400

# a PLACED order is not visible to admins
$r = PlaceOrder 'STORE_PICKUP' 'PAY_AT_STORE'
$placed = @($r.json.data.orders)[0]
Check 'PLACED order: 404' (Call 'PATCH' "/admin/orders/$($placed.id)" $admin @{ status = 'CANCELLED' }).status 404
Check 'unknown order: 404' (Call 'PATCH' '/admin/orders/00000000-0000-4000-8000-000000000000' $admin @{ status = 'CANCELLED' }).status 404

# ---- 4. validation and transitions ----
Check 'empty body: 400' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{}).status 400
Check 'unknown key: 400' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ total = 1 }).status 400
Check 'pickup order out for delivery: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ status = 'OUT_FOR_DELIVERY' }).status 409
Check 'CONFIRMED -> COMPLETED: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ status = 'COMPLETED' }).status 409
Check 'refund an unpaid order: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ paymentStatus = 'REFUNDED' }).status 409

$r = Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ status = 'READY_FOR_PICKUP'; paymentStatus = 'PAID' }
Check 'ready for pickup + paid: 200' $r.status 200
Check 'status is READY_FOR_PICKUP' $r.json.data.status 'READY_FOR_PICKUP'
Check 'payment is PAID' $r.json.data.paymentStatus 'PAID'
Check 'response has customer' ($r.json.data.customer.id -ne $null) $true
Check 'paid twice: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ paymentStatus = 'PAID' }).status 409
Check 'refund while not cancelled: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ paymentStatus = 'REFUNDED' }).status 409
$r = Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ status = 'COMPLETED' }
Check 'READY_FOR_PICKUP -> COMPLETED: 200' $r.status 200
Check 'completed bKash stays PAID' $r.json.data.paymentStatus 'PAID'
Check 'COMPLETED -> CANCELLED: 409' (Call 'PATCH' "/admin/orders/$($pick.id)" $admin @{ status = 'CANCELLED' }).status 409

# delivery: paid, then cancelled + refunded, stock comes back
Check 'delivery -> OUT_FOR_DELIVERY: 200' (Call 'PATCH' "/admin/orders/$($del.id)" $admin @{ status = 'OUT_FOR_DELIVERY' }).status 200
Check 'delivery paid: 200' (Call 'PATCH' "/admin/orders/$($del.id)" $admin @{ paymentStatus = 'PAID' }).status 200
Check 'paid on a cancel request: 409' (Call 'PATCH' "/admin/orders/$($del.id)" $admin @{ status = 'CANCELLED'; paymentStatus = 'PAID' }).status 409
$before = Stock
$r = Call 'PATCH' "/admin/orders/$($del.id)" $admin @{ status = 'CANCELLED'; paymentStatus = 'REFUNDED' }
Check 'cancel + refund: 200' $r.status 200
Check 'status CANCELLED' $r.json.data.status 'CANCELLED'
Check 'payment REFUNDED' $r.json.data.paymentStatus 'REFUNDED'
Check 'stock restored' (Stock) ($before + 1)

# ---- 5. notifications ----
$n = @((Call 'GET' '/notifications?limit=50' $cust $null).json.data | Where-Object { $_.data.orderId -eq $del.id -and $_.title -like '*Vendors Hub*' })
Check 'customer notified of the admin cancel' ($n.Count -ge 1) $true
$n = @((Call 'GET' '/notifications?limit=50' $owner $null).json.data | Where-Object { $_.data.orderId -eq $del.id -and $_.title -like '*Vendors Hub*' })
Check 'shop notified of the admin cancel' ($n.Count -ge 1) $true

# cleanup
Call 'POST' "/orders/$($placed.id)/cancel" $cust @{ reason = 'Test cleanup' } | Out-Null

Write-Host ''
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
