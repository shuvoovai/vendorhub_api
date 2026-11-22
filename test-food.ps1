# test-food.ps1 (food corner: vendors only, server-side prices, admin status flow and menu)
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
    if ($null -ne $body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)) }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); headers = $r.Headers } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what not found" -ForegroundColor Red; exit 1 } }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test'    # TechZone owner
$staff = Login 'owner2@vendorshub.test'    # also a shop owner / TechZone staff
$order = @{ quantity = 2; name = 'Rahim Uddin'; phone = '01712345678'; address = 'Shop 12, Level 4, Jamuna Future Park'; note = 'Less spicy' }

# ---- 1. access: vendors only ----
Check 'guest: /food/items needs login (401)' (Call 'GET' '/food/items' $null $null).status 401
Check 'customer: /food/items 403' (Call 'GET' '/food/items' $cust $null).status 403
Check 'customer: /food/orders 403' (Call 'POST' '/food/orders' $cust $order).status 403
Check 'customer: /me/food-orders 403' (Call 'GET' '/me/food-orders' $cust $null).status 403
$items = Call 'GET' '/food/items' $owner $null
Check 'shop owner sees the menu' $items.status 200
$menu = @($items.json.data)
Check 'six seeded items' $menu.Count 6
Check 'menu is private' ([string]$items.headers['Cache-Control']) 'private, no-store'
$first = $menu[0]
foreach ($f in @('id', 'nameEn', 'nameBn', 'descriptionEn', 'descriptionBn', 'price', 'emoji', 'isAvailable')) {
    Check "item has $f" ($null -ne $first.PSObject.Properties[$f]) $true
}
Check 'item has no extra fields' @($first.PSObject.Properties).Count 8
Check 'sorted by sortOrder (biryani first)' $first.nameEn 'Chicken Biryani'
Check 'admin sees the menu too' (Call 'GET' '/food/items' $admin $null).status 200

# ---- 2. ordering: the server sets the price ----
$o = $order.Clone(); $o.itemId = $first.id; $o.price = 1; $o.unitPrice = 1; $o.total = 1; $o.shopId = '00000000-0000-4000-8000-000000000000'
$r = Call 'POST' '/food/orders' $owner $o
Check 'owner orders: 201' $r.status 201
$orderId = $r.json.data.id
Check 'client price ignored: unitPrice from the menu' $r.json.data.unitPrice $first.price
Check 'total calculated on the server' $r.json.data.total ($first.price * 2)
Check 'status starts PENDING' $r.json.data.status 'PENDING'
Check 'item name snapshot' $r.json.data.itemName $first.nameEn
$s = $order.Clone(); $s.itemId = $menu[1].id; $s.quantity = 1
Check 'staff/owner of another shop orders too' (Call 'POST' '/food/orders' $staff $s).status 201
$bad = $order.Clone(); $bad.itemId = $first.id
foreach ($case in @(
        @('invalid phone', 'phone', '0171234567'), @('phone with letters', 'phone', '0171234567a'), @('phone 012 prefix', 'phone', '01212345678'),
        @('quantity 0', 'quantity', 0), @('quantity 21', 'quantity', 21), @('short name', 'name', 'A'),
        @('short address', 'address', 'abc'), @('HTML in note', 'note', '<script>x</script>'), @('bad item id', 'itemId', 'abc'))) {
    $b = $bad.Clone(); $b[$case[1]] = $case[2]
    Check "$($case[0]): 400" (Call 'POST' '/food/orders' $owner $b).status 400
}
$ghost = $bad.Clone(); $ghost.itemId = '00000000-0000-4000-8000-000000000000'
Check 'unknown item: 404' (Call 'POST' '/food/orders' $owner $ghost).status 404
$mine = @((Call 'GET' '/me/food-orders' $owner $null).json.data)
Check 'my orders: only my own' (@($mine | Where-Object { $_.id -eq $orderId }).Count -eq 1 -and $mine.Count -eq 1) $true

# ---- 3. admin: list, transitions ----
Check 'non-admin: /admin/food-orders 403' (Call 'GET' '/admin/food-orders' $owner $null).status 403
Check 'non-admin: PATCH 403' (Call 'PATCH' "/admin/food-orders/$orderId" $owner @{ status = 'CONFIRMED' }).status 403
Check 'non-admin: /admin/food-items 403' (Call 'GET' '/admin/food-items' $owner $null).status 403
$list = Call 'GET' '/admin/food-orders?status=PENDING' $admin $null
Check 'admin lists pending orders' (@($list.json.data).Count) 2
$row = @($list.json.data | Where-Object { $_.id -eq $orderId })[0]
Check 'admin list has the vendor name' ([bool]$row.vendor.name) $true
Check 'admin list has the shop name' $row.shop.name 'TechZone Electronics'
Check 'admin list is paginated' $list.json.meta.pagination.total 2
Check 'bad status filter: 400' (Call 'GET' '/admin/food-orders?status=LOST' $admin $null).status 400
Check 'bad id: 400' (Call 'PATCH' '/admin/food-orders/abc' $admin @{ status = 'CONFIRMED' }).status 400
Check 'unknown status value: 400' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'SHIPPED' }).status 400
Check 'PENDING -> DELIVERED: 409' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'DELIVERED' }).status 409
Check 'PENDING -> CONFIRMED' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'CONFIRMED' }).status 200
Check 'CONFIRMED -> CONFIRMED: 409' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'CONFIRMED' }).status 409
Check 'CONFIRMED -> DELIVERED' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'DELIVERED' }).status 200
Check 'DELIVERED -> CANCELLED: 409' (Call 'PATCH' "/admin/food-orders/$orderId" $admin @{ status = 'CANCELLED' }).status 409
Check 'the vendor sees DELIVERED' (@((Call 'GET' '/me/food-orders' $owner $null).json.data)[0].status) 'DELIVERED'
$notes = @((Call 'GET' '/notifications?limit=50' $owner $null).json.data | Where-Object { $_.type -eq 'FOOD_ORDER_STATUS' })
Check 'the vendor was notified' ($notes.Count -ge 2) $true
$an = @((Call 'GET' '/notifications?limit=50' $admin $null).json.data | Where-Object { $_.type -eq 'FOOD_ORDER_NEW' })
Check 'admins were notified of new orders' ($an.Count -ge 2) $true
$logs = @((Call 'GET' "/admin/audit-logs?entityType=FoodOrder&entityId=$orderId&limit=50" $admin $null).json.data)
Check 'status changes are audited' (@($logs | Where-Object { $_.action -eq 'food_order.status_changed' }).Count) 2

# ---- 4. menu management ----
$r = Call 'POST' '/admin/food-items' $admin @{ nameEn = 'Test Samosa'; nameBn = 'Samosa BN'; price = 30; emoji = 'X'; sortOrder = 99 }
Check 'admin adds an item' $r.status 201
$newId = $r.json.data.id
Check 'price 0: 400' (Call 'POST' '/admin/food-items' $admin @{ nameEn = 'A'; nameBn = 'B'; price = 0 }).status 400
Check 'name over 60: 400' (Call 'POST' '/admin/food-items' $admin @{ nameEn = ('n' * 61); nameBn = 'B'; price = 5 }).status 400
Check 'emoji over 8 chars: 400' (Call 'POST' '/admin/food-items' $admin @{ nameEn = 'A'; nameBn = 'B'; price = 5; emoji = '123456789' }).status 400
Check 'unknown field: 400' (Call 'POST' '/admin/food-items' $admin @{ nameEn = 'A'; nameBn = 'B'; price = 5; color = 'red' }).status 400
Check 'admin marks it unavailable' (Call 'PATCH' "/admin/food-items/$newId" $admin @{ isAvailable = $false }).status 200
Check 'hidden from vendors' (@((Call 'GET' '/food/items' $owner $null).json.data | Where-Object { $_.id -eq $newId }).Count) 0
$u = $order.Clone(); $u.itemId = $newId
Check 'ordering an unavailable item: 409' (Call 'POST' '/food/orders' $owner $u).status 409
Check 'admin list shows unavailable items' (@((Call 'GET' '/admin/food-items' $admin $null).json.data | Where-Object { $_.id -eq $newId }).Count) 1
Check 'admin deletes the unused item' (Call 'DELETE' "/admin/food-items/$newId" $admin $null).status 200
Check 'an ordered item cannot be deleted: 409' (Call 'DELETE' "/admin/food-items/$($first.id)" $admin $null).status 409
Check 'delete bad id: 400' (Call 'DELETE' '/admin/food-items/xyz' $admin $null).status 400

Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
