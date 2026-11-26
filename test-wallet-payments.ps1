# test-wallet-payments.ps1 (bKash / Nagad: merchant numbers, paymentDetails rules, admin-only wallet details)
# Run from the project root while the test API is running (. .\test-env.ps1; npm run dev).
$base = 'http://localhost:4000/api/v1'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
# returns status, parsed json and the raw text (also for error answers)
function Call($method, $path, $token, $body) {
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true }
    if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 6)) }
    try {
        $r = Invoke-WebRequest @p
        return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); raw = $r.Content }
    } catch {
        if (-not $_.Exception.Response) { return @{ status = 0; json = $null; raw = '' } }
        $raw = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
        $json = $null; try { $json = $raw | ConvertFrom-Json } catch { }
        return @{ status = [int]$_.Exception.Response.StatusCode; json = $json; raw = $raw }
    }
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

$wallet = '01811223344'
$trx = 'NG7Q2W9E1R'
function PlaceOrder($delivery, $payment, $details) {
    Call 'DELETE' '/cart' $cust $null | Out-Null
    Call 'POST' '/cart/items' $cust @{ listingId = $listing.id; quantity = 1 } | Out-Null
    $c = @{ shopId = $shopId; deliveryMethod = $delivery; paymentMethod = $payment }
    if ($delivery -eq 'VENDOR_DELIVERY') { $c.deliveryAddress = 'House 12, Road 5, Dhanmondi, Dhaka' }
    if ($null -ne $details) { $c.paymentDetails = $details }
    return Call 'POST' '/checkout' $cust @{ shops = @($c) }
}

# ---- 1. where to send the money (public) ----
$o = Call 'GET' '/payment-options' $null $null
Check 'payment options: 200 without login' $o.status 200
Check 'bKash merchant number' $o.json.data.bkash.merchantNumber '01900000001'
Check 'Nagad merchant number' $o.json.data.nagad.merchantNumber '01900000002'

# ---- 2. paymentDetails rules ----
Check 'BKASH without paymentDetails: 400' (PlaceOrder 'STORE_PICKUP' 'BKASH' $null).status 400
Check 'NAGAD without paymentDetails: 400' (PlaceOrder 'STORE_PICKUP' 'NAGAD' $null).status 400
Check 'paymentDetails with CASH_ON_DELIVERY: 400' (PlaceOrder 'VENDOR_DELIVERY' 'CASH_ON_DELIVERY' @{ walletNumber = $wallet }).status 400
Check 'paymentDetails with PAY_AT_STORE: 400' (PlaceOrder 'STORE_PICKUP' 'PAY_AT_STORE' @{ walletNumber = $wallet }).status 400
Check 'paymentDetails with ONLINE: 400' (PlaceOrder 'STORE_PICKUP' 'ONLINE' @{ walletNumber = $wallet }).status 400
$bad = PlaceOrder 'STORE_PICKUP' 'NAGAD' @{ walletNumber = '01298765432' }
Check 'a wallet number that is not a BD mobile number: 400' $bad.status 400
Check 'the error does not echo the number' ($bad.raw -like '*01298765432*') $false
Check 'a 10-digit wallet number: 400' (PlaceOrder 'STORE_PICKUP' 'NAGAD' @{ walletNumber = '0181122334' }).status 400
Check 'a bad transaction ID: 400' (PlaceOrder 'STORE_PICKUP' 'NAGAD' @{ walletNumber = $wallet; transactionId = 'AB-12' }).status 400
$card = PlaceOrder 'STORE_PICKUP' 'NAGAD' @{ walletNumber = $wallet; cardNumber = '4111111111111111' }
Check 'card details in paymentDetails: 400' $card.status 400
Check 'the error does not echo the card number' ($card.raw -like '*4111111111111111*') $false
Check 'the cart is kept after a rejected checkout' (@((Call 'GET' '/cart' $cust $null).json.data.shops).Count -ge 1) $true

# ---- 3. a valid Nagad order ----
$r = PlaceOrder 'STORE_PICKUP' 'NAGAD' @{ walletNumber = $wallet; transactionId = $trx.ToLower() }
Check 'valid NAGAD with store pickup: 201' $r.status 201
$order = @($r.json.data.orders)[0]
Check 'payment method NAGAD' $order.paymentMethod 'NAGAD'
Check 'payment PENDING' $order.paymentStatus 'PENDING'
Check 'the checkout answer has no wallet number' ($r.raw -like "*$wallet*") $false
Check 'the checkout answer has no TrxID' ($r.raw -like "*$trx*") $false
$d = PlaceOrder 'VENDOR_DELIVERY' 'NAGAD' @{ walletNumber = $wallet }
Check 'valid NAGAD with delivery (no TrxID): 201' $d.status 201
$delOrder = @($d.json.data.orders)[0]
Check 'valid BKASH: 201' (PlaceOrder 'STORE_PICKUP' 'BKASH' @{ walletNumber = $wallet }).status 201

# ---- 4. only admins see the wallet details ----
$mine = Call 'GET' "/orders/$($order.id)" $cust $null
Check 'customer order: 200' $mine.status 200
Check 'customer order has no wallet number' ($mine.raw -like "*$wallet*") $false
$shopView = Call 'GET' "/shops/$shopId/orders/$($order.id)" $owner $null
Check 'shop order: 200' $shopView.status 200
Check 'shop order has no wallet number' ($shopView.raw -like "*$wallet*") $false
Check 'shop order has no TrxID' ($shopView.raw -like "*$trx*") $false
Check 'shop order has no wallet fields at all' ($shopView.raw -like '*walletNumber*') $false
$shopList = Call 'GET' "/shops/$shopId/orders?limit=50" $owner $null
Check 'shop order list has no wallet number' ($shopList.raw -like "*$wallet*") $false

Check 'vendor confirms the Nagad order without waiting: 200' (Call 'POST' "/shops/$shopId/orders/$($order.id)/status" $owner @{ status = 'CONFIRMED' }).status 200
Check 'vendor confirms the Nagad delivery: 200' (Call 'POST' "/shops/$shopId/orders/$($delOrder.id)/status" $owner @{ status = 'CONFIRMED' }).status 200
$row = @((Call 'GET' '/admin/orders?limit=50' $admin $null).json.data | Where-Object { $_.id -eq $order.id })[0]
Check 'admin sees the order' ($null -ne $row) $true
$pay = @($row.payments)[0]
Check 'one payment row' @($row.payments).Count 1
Check 'payment provider nagad' $pay.provider 'nagad'
Check 'payment amount is the order total' $pay.amount $order.total
Check 'payment PENDING' $pay.status 'PENDING'
Check 'admin sees the wallet number' $pay.walletNumber $wallet
Check 'admin sees the TrxID in uppercase' $pay.transactionId $trx
$delRow = @((Call 'GET' '/admin/orders?limit=50' $admin $null).json.data | Where-Object { $_.id -eq $delOrder.id })[0]
Check 'no TrxID given: transactionId null' ($null -eq @($delRow.payments)[0].transactionId) $true

# ---- 5. the admin marks it paid (payment only, no status change) ----
$m = Call 'PATCH' "/admin/orders/$($order.id)" $admin @{ paymentStatus = 'PAID' }
Check 'admin marks the Nagad payment PAID: 200' $m.status 200
Check 'order payment PAID' $m.json.data.paymentStatus 'PAID'
Check 'payment row PAID' @($m.json.data.payments)[0].status 'PAID'
Check 'still the same single payment row' @($m.json.data.payments).Count 1
Check 'order status unchanged' $m.json.data.status 'CONFIRMED'

# cleanup: cancel the delivery order through the admin (stock comes back)
Call 'PATCH' "/admin/orders/$($delOrder.id)" $admin @{ status = 'CANCELLED' } | Out-Null

Write-Host ''
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
