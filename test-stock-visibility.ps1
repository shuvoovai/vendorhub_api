# test-stock-visibility.ps1 (who may see a listing's stock number: PUBLIC / VENDORS / HIDDEN)
# Run from the project root on fresh seed data while "npm run dev" is running.
# Seed: owner1 owns TechZone (verified), owner2 owns Dhaka Mobile House (verified) AND is TechZone staff,
# owner3 owns Gadget Galaxy (verified). A freshly registered shop owner has an UNVERIFIED shop.
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
    catch {
        if ($_.Exception.Response) {
            $body = $null
            try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
            return @{ status = [int]$_.Exception.Response.StatusCode; json = $null; raw = $body }
        }
        return @{ status = 0; json = $null; raw = $null }
    }
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
$staff = Login 'owner2@vendorshub.test'    # TechZone staff (and owner of another verified shop)
$other = Login 'owner3@vendorshub.test'    # another verified shop's owner, not in TechZone
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$reg = Call 'POST' '/auth/register' $null @{ name = 'Unverified Owner'; email = "sv$stamp@vendorshub.test"; password = 'Password123!'; role = 'SHOP_OWNER' }
$unverified = $reg.json.data.accessToken
Need $unverified 'the unverified owner'
Need ((Call 'POST' '/shops' $unverified @{ name = "Stock Test $stamp"; addressLine = 'Road 3, Test Area, Dhaka'; phone = '01712345678' }).status -eq 201) 'the unverified shop'

$techId = (Call 'GET' '/shops/techzone-electronics' $null $null).json.data.id
Need $techId 'TechZone'
$listing = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.isActive -and $_.availability -ne 'OUT_OF_STOCK' })[0]
Need $listing 'a TechZone listing'
$lid = $listing.id
$slug = $listing.product.slug
$stock = 7

# the listing's stockQty in each public response, for one viewer
function Get-DetailQty($token) { return @(@($(Call 'GET' "/products/$($slug)?listingId=$lid" $token $null).json.data.selectedListing) | ForEach-Object { $_.stockQty })[0] }
function Get-CompareQty($token) { return @((Call 'GET' "/products/$slug/listings" $token $null).json.data | Where-Object { $_.id -eq $lid } | ForEach-Object { $_.stockQty })[0] }
function Get-StorefrontQty($token) { return @((Call 'GET' '/shops/techzone-electronics/products?limit=50' $token $null).json.data | Where-Object { $_.listingId -eq $lid } | ForEach-Object { $_.stockQty })[0] }
function SeeAll($label, $token, $expected) {
    Check "$label - product page" (Get-DetailQty $token) $expected
    Check "$label - compare table" (Get-CompareQty $token) $expected
    Check "$label - shop storefront" (Get-StorefrontQty $token) $expected
}
function SetVis($v) { return (Call 'PATCH' "/shops/$techId/listings/$lid" $owner @{ stockVisibility = $v }) }

# ---- 1. owner endpoints ----
$r = Call 'PATCH' "/shops/$techId/listings/$lid" $owner @{ stockQty = $stock }
Check 'owner sets stockQty' $r.status 200
Check 'existing listings default to HIDDEN' $r.json.data.stockVisibility 'HIDDEN'
Check 'invalid stockVisibility: 400' (SetVis 'EVERYONE').status 400
Check 'lowercase value: 400' (SetVis 'public').status 400
Check 'a customer cannot change it: 403' (Call 'PATCH' "/shops/$techId/listings/$lid" $cust @{ stockVisibility = 'PUBLIC' }).status 403
Check "another shop's owner cannot change it: 403" (Call 'PATCH' "/shops/$techId/listings/$lid" $other @{ stockVisibility = 'PUBLIC' }).status 403

# ---- 2. PUBLIC ----
$r = SetVis 'PUBLIC'
Check 'owner sets PUBLIC' $r.status 200
Check 'owner response returns stockVisibility' $r.json.data.stockVisibility 'PUBLIC'
SeeAll 'PUBLIC: guest' $null $stock
SeeAll 'PUBLIC: customer' $cust $stock
$h = Call 'GET' "/products/$slug" $null $null
# other shops' listings on the same page stay HIDDEN (the default): a guest never gets their numbers
$others = @($h.json.data.otherListings) + @($h.json.data.selectedListing) | Where-Object { $_ -and $_.id -ne $lid }
Check 'PUBLIC: other (HIDDEN) listings on the page stay null for a guest' (@($others | Where-Object { $null -ne $_.stockQty }).Count) 0
Check 'public stockVisibility is not exposed' ($h.raw -match 'stockVisibility') $false

# ---- 3. VENDORS ----
Check 'owner sets VENDORS' (SetVis 'VENDORS').status 200
SeeAll 'VENDORS: guest' $null $null
SeeAll 'VENDORS: customer' $cust $null
SeeAll 'VENDORS: unverified shop owner' $unverified $null
SeeAll "VENDORS: another verified shop's owner" $other $stock
SeeAll 'VENDORS: own owner' $owner $stock
SeeAll 'VENDORS: own staff' $staff $stock
$h = Call 'GET' "/products/$slug" $null $null
Check 'VENDORS: response is private' ([string]$h.headers['Cache-Control']) 'private, no-store'
Check 'VENDORS: Vary Authorization' ([string]$h.headers['Vary'] -match 'Authorization') $true
Check 'VENDORS: storefront is private too' ([string](Call 'GET' '/shops/techzone-electronics/products?limit=50' $null $null).headers['Cache-Control']) 'private, no-store'

# ---- 4. HIDDEN ----
Check 'owner sets HIDDEN' (SetVis 'HIDDEN').status 200
SeeAll 'HIDDEN: guest' $null $null
SeeAll 'HIDDEN: customer' $cust $null
SeeAll "HIDDEN: another verified shop's owner" $other $null
SeeAll 'HIDDEN: own owner' $owner $stock
SeeAll 'HIDDEN: own staff' $staff $stock
SeeAll 'HIDDEN: admin' $admin $stock
$g = Call 'GET' "/products/$($slug)?listingId=$lid" $null $null
Check 'HIDDEN: stockQty field is kept (null)' ($null -ne $g.json.data.selectedListing.PSObject.Properties['stockQty']) $true
Check 'HIDDEN: availability is still sent' ([bool]$g.json.data.selectedListing.availability) $true

# ---- 5. cart: field hidden, real stock enforced, no number in errors ----
Call 'DELETE' '/cart' $cust $null | Out-Null
Check 'customer adds 1' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; quantity = 1 }).status 200
$line = @(@((Call 'GET' '/cart' $cust $null).json.data.shops)[0].items)[0]
Check 'HIDDEN: cart stockQty is null for the customer' ($null -eq $line.stockQty) $true
Check 'HIDDEN: cart keeps the field' ($null -ne $line.PSObject.Properties['stockQty']) $true
Check 'stock 2 for the over-stock test' (Call 'PATCH' "/shops/$techId/listings/$lid" $owner @{ stockQty = 2 }).status 200
$over = Call 'PATCH' "/cart/items/$($line.id)" $cust @{ quantity = 3 }
Check 'more than the stock: 409' $over.status 409
Check 'the error does not reveal the number' ($over.raw -match '\b2\b') $false
$add = Call 'POST' '/cart/items' $cust @{ listingId = $lid; quantity = 5 }
Check 'adding more than the stock: 409' $add.status 409
Check 'that error does not reveal the number either' ($add.raw -match '\b2\b') $false
Call 'DELETE' '/cart' $cust $null | Out-Null

# ---- 6. audit log ----
$logs = @((Call 'GET' "/admin/audit-logs?entityType=ShopListing&entityId=$lid&limit=50" $admin $null).json.data)
$changes = @($logs | Where-Object { $_.action -eq 'listing.stock_visibility_changed' })
Check 'every visibility change is audited' $changes.Count 3

Call 'PATCH' "/shops/$techId/listings/$lid" $owner @{ stockQty = $listing.stockQty } | Out-Null
Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
