# test-variants.ps1 (listing variants: owner setup, public product page, cards, cart, merge, checkout, cancel)
# Run from the project root on FRESH seed data while "npm run dev" is running.
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
    if ($null -ne $body) {
        $json = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Compress -Depth 8 } # a string is sent as-is
        $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); raw = $r.Content } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null; raw = '' } } return @{ status = 0; json = $null; raw = '' } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what not found" -ForegroundColor Red; exit 1 } }
function Lines($cart) { return , @(@($cart.shops) | ForEach-Object { $_.items } | Where-Object { $_ }) }
function V($color, $size, $price, $stock, $active) {
    $v = @{ options = @{ Color = $color; Size = $size }; price = $price; stockQty = $stock }
    if ($null -ne $active) { $v.isActive = $active }
    return $v
}

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$owner = Login 'owner1@vendorshub.test'   # TechZone owner
$other = Login 'owner3@vendorshub.test'   # another shop's owner
$cust = Login 'customer@vendorshub.test'
$techId = (Call 'GET' '/shops/techzone-electronics' $null $null).json.data.id
$listing = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.isActive -and $_.availability -ne 'OUT_OF_STOCK' } | Sort-Object price)[0]
Need $listing 'a TechZone listing'
$lid = $listing.id
$slug = $listing.product.slug
$lp = $listing.price
$path = "/shops/$techId/listings/$lid"
$opts = @(@{ name = 'Color'; values = @('Red', 'Blue') }, @{ name = 'Size'; values = @('M', 'L') })

# ---- 1. owner validation ----
Check 'counts stock first: set stockQty 50' (Call 'PATCH' $path $owner @{ stockQty = 50 }).status 200
$bad = @(
    @('options without variants', @{ variantOptions = $opts }),
    @('variants without options', @{ variants = @((V 'Red' 'M' $null 5 $null)) }),
    @('4 options', @{ variantOptions = @(@{ name = 'A'; values = @('1') }, @{ name = 'B'; values = @('1') }, @{ name = 'C'; values = @('1') }, @{ name = 'D'; values = @('1') }); variants = @(@{ options = @{ A = '1'; B = '1'; C = '1'; D = '1' }; stockQty = 1 }) }),
    @('duplicate option names (case)', '{"variantOptions":[{"name":"Color","values":["Red"]},{"name":"color","values":["Blue"]}],"variants":[{"options":{"Color":"Red","color":"Blue"},"stockQty":1}]}'),
    @('duplicate values', @{ variantOptions = @(@{ name = 'Color'; values = @('Red', 'red') }); variants = @(@{ options = @{ Color = 'Red' }; stockQty = 1 }) }),
    @('21 values', @{ variantOptions = @(@{ name = 'N'; values = @(1..21 | ForEach-Object { "v$_" }) }); variants = @(@{ options = @{ N = 'v1' }; stockQty = 1 }) }),
    @('value not in the option', @{ variantOptions = $opts; variants = @((V 'Green' 'M' $null 5 $null)) }),
    @('a missing option', @{ variantOptions = $opts; variants = @(@{ options = @{ Color = 'Red' }; stockQty = 5 }) }),
    @('an unknown option', @{ variantOptions = $opts; variants = @(@{ options = @{ Color = 'Red'; Size = 'M'; Fit = 'Slim' }; stockQty = 5 }) }),
    @('duplicate combination (case)', @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null 5 $null), (V 'red' 'm' $null 3 $null)) }),
    @('price 0', @{ variantOptions = $opts; variants = @((V 'Red' 'M' 0 5 $null)) }),
    @('no stockQty while counting stock', @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null $null $null)) }),
    @('no active variant', @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null 5 $false)) }),
    @('name over 30', @{ variantOptions = @(@{ name = ('n' * 31); values = @('x') }); variants = @(@{ options = @{ ('n' * 31) = 'x' }; stockQty = 1 }) })
)
foreach ($c in $bad) { Check "$($c[0]): 400" (Call 'PATCH' $path $owner $c[1]).status 400 }
Check "another shop's owner: 403" (Call 'PATCH' $path $other @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null 5 $null)) }).status 403

# ---- 2. owner sets variants ----
$body = @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null 4 $null), (V 'Red' 'L' ($lp + 500) 0 $null), (V 'Blue' 'M' ($lp + 100) 7 $null), (V 'Blue' 'L' $null 9 $false)) }
$r = Call 'PATCH' $path $owner $body
Check 'set variants: 200' $r.status 200
$vs = @($r.json.data.variants)
Check '4 variants stored' $vs.Count 4
Check 'listing stockQty = sum of active variants (4+0+7)' $r.json.data.stockQty 11
Check 'listing availability derived' $r.json.data.availability 'IN_STOCK'
Check 'owner sees variant stockQty' (@($vs | Where-Object { $_.options.Color -eq 'Blue' -and $_.options.Size -eq 'M' })[0].stockQty) 7
$redM = (@($vs | Where-Object { $_.options.Color -eq 'Red' -and $_.options.Size -eq 'M' })[0]).id
$redL = (@($vs | Where-Object { $_.options.Color -eq 'Red' -and $_.options.Size -eq 'L' })[0]).id
$blueM = (@($vs | Where-Object { $_.options.Color -eq 'Blue' -and $_.options.Size -eq 'M' })[0]).id
$blueL = (@($vs | Where-Object { $_.options.Color -eq 'Blue' -and $_.options.Size -eq 'L' })[0]).id
$own = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.id -eq $lid })[0]
Check 'owner GET has variantOptions' (@($own.variantOptions).Count) 2
Check 'owner GET has variants with stockQty' (@($own.variants | Where-Object { $null -ne $_.PSObject.Properties['stockQty'] }).Count) 4
$r = Call 'PATCH' $path $owner @{ variantOptions = $opts; variants = @((V 'red' 'm' $null 4 $null), (V 'Red' 'L' ($lp + 500) 0 $null), (V 'Blue' 'M' ($lp + 100) 7 $null)) }
Check 'resend (other letter case): 200' $r.status 200
Check 'ids are kept (upsert by combination)' (@($r.json.data.variants | Where-Object { $_.id -eq $redM }).Count) 1
Check 'a combination not sent becomes inactive' (@($r.json.data.variants | Where-Object { $_.id -eq $blueL })[0].isActive) $false
Check 'value spelling from the option list' (@($r.json.data.variants | Where-Object { $_.id -eq $redM })[0].options.Color) 'Red'

# ---- 3. public product page and cards ----
$d = (Call 'GET' "/products/$($slug)?listingId=$lid" $null $null)
$sel = $d.json.data.selectedListing
Check 'public: variantOptions' (@($sel.variantOptions).Count) 2
Check 'public: only active variants' (@($sel.variants).Count) 3
Check 'public: no stockQty on variants' (@($sel.variants | Where-Object { $null -ne $_.PSObject.Properties['stockQty'] }).Count) 0
Check 'public: never a stock number in the raw answer for variants' ($d.raw -match '"variants":\[[^\]]*stockQty') $false
Check 'public: final price = listing price when null' (@($sel.variants | Where-Object { $_.id -eq $redM })[0].price) $lp
Check 'public: final price = variant price' (@($sel.variants | Where-Object { $_.id -eq $blueM })[0].price) ($lp + 100)
Check 'public: variant out of stock' (@($sel.variants | Where-Object { $_.id -eq $redL })[0].availability) 'OUT_OF_STOCK'
Check 'public: variant LIMITED (4)' (@($sel.variants | Where-Object { $_.id -eq $redM })[0].availability) 'LIMITED'
Check 'public: label' (@($sel.variants | Where-Object { $_.id -eq $blueM })[0].label) 'Blue / M'
Check 'compare table has variants too' (@(@((Call 'GET' "/products/$slug/listings" $null $null).json.data | Where-Object { $_.id -eq $lid })[0].variants).Count) 3
$card = @((Call 'GET' "/products?shopId=$techId&limit=48" $null $null).json.data | Where-Object { $_.slug -eq $slug })[0]
Check 'shop page card: hasVariants' $card.hasVariants $true
Check 'cards always have hasVariants' (@((Call 'GET' '/products?limit=48' $null $null).json.data | Where-Object { $null -eq $_.PSObject.Properties['hasVariants'] }).Count) 0

# ---- 4. cart ----
Call 'DELETE' '/cart' $cust $null | Out-Null
Check 'no variantId: 400' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; quantity = 1 }).status 400
Check 'unknown variantId: 404' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = '00000000-0000-4000-8000-000000000000' }).status 404
Check 'inactive variant: 404' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = $blueL }).status 404
Check 'out-of-stock variant: 409' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = $redL }).status 409
$otherListing = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.isActive -and $_.id -ne $lid -and $_.availability -ne 'OUT_OF_STOCK' })[0]
Check 'variantId on a listing without variants: 400' (Call 'POST' '/cart/items' $cust @{ listingId = $otherListing.id; variantId = $redM }).status 400
$r = Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = $redM; quantity = 3 }
Check 'add Red / M x3: 200' $r.status 200
Check 'over the variant stock (3+2 > 4): 409' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = $redM; quantity = 2 }).status 409
$r = Call 'POST' '/cart/items' $cust @{ listingId = $lid; variantId = $blueM; quantity = 2 }
$ls = Lines $r.json.data
Check 'two lines for two variants of one listing' (@($ls | Where-Object { $_.listingId -eq $lid }).Count) 2
$lineRed = @($ls | Where-Object { $_.variant.id -eq $redM })[0]
$lineBlue = @($ls | Where-Object { $_.variant.id -eq $blueM })[0]
Check 'variant label in the cart' $lineRed.variant.label 'Red / M'
Check 'price: listing price (variant price null)' $lineRed.unitPrice $lp
Check 'price: variant price' $lineBlue.unitPrice ($lp + 100)
Check 'PATCH over the variant stock: 409' (Call 'PATCH' "/cart/items/$($lineRed.id)" $cust @{ quantity = 5 }).status 409
Check 'PATCH within the variant stock: 200' (Call 'PATCH' "/cart/items/$($lineRed.id)" $cust @{ quantity = 4 }).status 200
$r = Call 'POST' '/cart/items' $cust @{ listingId = $otherListing.id; quantity = 1 }
Check 'add a listing without variants: 200' $r.status 200
$plain = @((Lines $r.json.data) | Where-Object { $_.listingId -eq $otherListing.id })[0]
Check 'a line without variants: variant null' ($null -ne $plain -and $null -eq $plain.variant) $true
Call 'DELETE' "/cart/items/$($plain.id)" $cust $null | Out-Null

# ---- 5. guest cart merge treats (listing, variant) as the line ----
$jar = Join-Path $env:TEMP 'vh-variants.jar'; if (Test-Path $jar) { Remove-Item $jar }
$bf = Join-Path $env:TEMP 'vh-variants-body.json'
function GuestAdd($variantId, $qty) {
    [IO.File]::WriteAllText($bf, (@{ listingId = $lid; variantId = $variantId; quantity = $qty } | ConvertTo-Json -Compress))
    return [int](& curl.exe -s -o NUL -w '%{http_code}' -b $jar -c $jar -X POST -H 'Content-Type: application/json' --data-binary "@$bf" "$base/cart/items")
}
Check 'guest adds Blue / M x3' (GuestAdd $blueM 3) 200
Check 'guest adds Red / M x1' (GuestAdd $redM 1) 200
$merged = (& curl.exe -s -b $jar -c $jar -X POST -H "Authorization: Bearer $cust" "$base/cart/merge") | ConvertFrom-Json
$ml = Lines $merged.data
Check 'merge: Blue / M added (2+3)' (@($ml | Where-Object { $_.variant.id -eq $blueM })[0].quantity) 5
Check 'merge: Red / M capped at its stock (4)' (@($ml | Where-Object { $_.variant.id -eq $redM })[0].quantity) 4
Check 'merge: still 2 lines for the listing' (@($ml | Where-Object { $_.listingId -eq $lid }).Count) 2
Remove-Item $jar, $bf -ErrorAction SilentlyContinue
Check 'Blue / M back to 2' (Call 'PATCH' "/cart/items/$($lineBlue.id)" $cust @{ quantity = 2 }).status 200

# ---- 6. checkout takes the variant stock and snapshots the label ----
$cart = (Call 'GET' '/cart' $cust $null).json.data
$choices = @($cart.shops | ForEach-Object {
    if ($_.shop.supportsDelivery) { @{ shopId = $_.shop.id; deliveryMethod = 'VENDOR_DELIVERY'; paymentMethod = 'CASH_ON_DELIVERY'; deliveryAddress = 'House 12, Road 5, Dhanmondi, Dhaka' } }
    else { @{ shopId = $_.shop.id; deliveryMethod = 'STORE_PICKUP'; paymentMethod = 'PAY_AT_STORE' } }
})
$r = Call 'POST' '/checkout' $cust @{ shops = $choices }
Check 'checkout: 201' $r.status 201
$order = @($r.json.data.orders | Where-Object { $_.shop.id -eq $techId })[0]
$oi = @($order.items)
Check 'order items have variantLabel' (@($oi | Where-Object { $_.variantLabel -eq 'Red / M' }).Count) 1
Check 'order item price snapshot (variant price)' (@($oi | Where-Object { $_.variantLabel -eq 'Blue / M' })[0].unitPrice) ($lp + 100)
$own = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.id -eq $lid })[0]
Check 'variant stock taken (Red / M 4-4)' (@($own.variants | Where-Object { $_.id -eq $redM })[0].stockQty) 0
Check 'variant stock taken (Blue / M 7-2)' (@($own.variants | Where-Object { $_.id -eq $blueM })[0].stockQty) 5
Check 'listing total taken too (11-6)' $own.stockQty 5
Check 'customer order shows variantLabel' (@((Call 'GET' "/orders/$($order.id)" $cust $null).json.data.items | Where-Object { $_.variantLabel -eq 'Red / M' }).Count) 1
Check 'shop order shows variantLabel' (@((Call 'GET' "/shops/$techId/orders/$($order.id)" $owner $null).json.data.items | Where-Object { $_.variantLabel -eq 'Red / M' }).Count) 1
Check 'public: Red / M now out of stock' (@((Call 'GET' "/products/$($slug)?listingId=$lid" $null $null).json.data.selectedListing.variants | Where-Object { $_.id -eq $redM })[0].availability) 'OUT_OF_STOCK'

# ---- 7. cancel gives the variant stock back ----
Check 'customer cancels: 200' (Call 'POST' "/orders/$($order.id)/cancel" $cust @{ reason = 'Changed my mind' }).status 200
$own = @((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.id -eq $lid })[0]
Check 'variant stock restored (Red / M)' (@($own.variants | Where-Object { $_.id -eq $redM })[0].stockQty) 4
Check 'variant stock restored (Blue / M)' (@($own.variants | Where-Object { $_.id -eq $blueM })[0].stockQty) 7
Check 'listing total restored' $own.stockQty 11

# ---- 8. a line made before variants existed must choose one ----
$r = Call 'PATCH' $path $owner @{ variantOptions = @(); variants = @() }
Check 'turn variants off: 200' $r.status 200
Check 'all variants inactive' (@($r.json.data.variants | Where-Object { $_.isActive }).Count) 0
Check 'public: no variants now' (@((Call 'GET' "/products/$($slug)?listingId=$lid" $null $null).json.data.selectedListing.variants).Count) 0
Call 'DELETE' '/cart' $cust $null | Out-Null
Check 'no variants: plain add works' (Call 'POST' '/cart/items' $cust @{ listingId = $lid; quantity = 1 }).status 200
Check 'turn variants on again' (Call 'PATCH' $path $owner @{ variantOptions = $opts; variants = @((V 'Red' 'M' $null 4 $null)) }).status 200
$line = @(Lines (Call 'GET' '/cart' $cust $null).json.data | Where-Object { $_.listingId -eq $lid })[0]
Check 'old variant-less line: VARIANT_REQUIRED' $line.problem 'VARIANT_REQUIRED'
Check 'checkout blocked: 409' (Call 'POST' '/checkout' $cust @{ shops = @(@{ shopId = $techId; deliveryMethod = 'STORE_PICKUP'; paymentMethod = 'PAY_AT_STORE' }) }).status 409
Check 'reused combination kept its id' (@((Call 'GET' "/shops/$techId/listings" $owner $null).json.data | Where-Object { $_.id -eq $lid })[0].variants | Where-Object { $_.isActive })[0].id $redM

# clean up: variants off, stock back to untracked, empty cart
Call 'DELETE' '/cart' $cust $null | Out-Null
Call 'PATCH' $path $owner @{ variantOptions = @(); variants = @() } | Out-Null
Call 'PATCH' $path $owner @{ stockQty = $listing.stockQty } | Out-Null

Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
