# test-random-sort.ps1 (GET /products?sort=random: a shuffle fixed by a seed, stable pages, the same filters
# and card prices as the other sorts). Run on fresh seed data while the test API is running.
$base = 'http://localhost:4000/api/v1'
$script:pass = 0
$script:fail = 0

function Check($name, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL  $name (got '$actual', expected '$expected')" -ForegroundColor Red; $script:fail++ }
}
function Call($path, $method = 'GET', $token = $null, $body = $null) {
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true }
    if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
    if ($null -ne $body) { $p.ContentType = 'application/json'; $p.Body = ($body | ConvertTo-Json -Compress -Depth 5) }
    try {
        $r = Invoke-WebRequest @p
        return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); headers = $r.Headers }
    }
    catch {
        if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null; headers = $null } }
        return @{ status = 0; json = $null; headers = $null }
    }
}
function Login($email) {
    $r = Call '/auth/login' 'POST' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what" -ForegroundColor Red; exit 1 } }
function Ids($r) { return (@($r.json.data) | ForEach-Object { $_.id }) -join ',' }
# every product of a query, page by page (limit 50)
function AllItems($query) {
    $items = @()
    $page = 1
    do {
        $r = Call "/products?$query&limit=50&page=$page"
        $items += @($r.json.data)
        $page++
    } while ($page -le $r.json.meta.pagination.totalPages)
    return $items
}

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

# one product sold out in every shop, so availableOnly has something to hide (restored at the end)
$tokens = @{
    'techzone-electronics' = (Login 'owner1@vendorshub.test')
    'dhaka-mobile-house'   = (Login 'owner2@vendorshub.test')
    'gadget-galaxy'        = (Login 'owner3@vendorshub.test')
}
$soldOut = @(AllItems 'sort=newest')[-1]
$restore = @()
foreach ($l in @((Call "/products/$($soldOut.slug)/listings").json.data)) {
    $tok = $tokens[$l.shop.slug]
    Need $tok "a login for $($l.shop.slug)"
    $own = @((Call "/shops/$($l.shop.id)/listings" 'GET' $tok).json.data | Where-Object { $_.id -eq $l.id })[0]
    $restore += @{ shopId = $l.shop.id; id = $l.id; token = $tok; availability = $own.availability; stockQty = $own.stockQty }
    Need ((Call "/shops/$($l.shop.id)/listings/$($l.id)" 'PATCH' $tok @{ availability = 'OUT_OF_STOCK'; stockQty = 0 }).status -eq 200) 'selling out a listing'
}

$full = @(AllItems 'sort=newest')
Need ($full.Count -ge 10) 'at least 10 products'
Need (@($full | Where-Object { $_.id -eq $soldOut.id -and $_.availability -eq 'OUT_OF_STOCK' }).Count -eq 1) 'the sold-out product'
$fullIds = ($full | ForEach-Object { $_.id } | Sort-Object) -join ','

# ---- 1. same seed = same order ----
$a1 = Call '/products?sort=random&seed=abc&limit=50'
$a2 = Call '/products?sort=random&seed=abc&limit=50'
Check 'sort=random: 200' $a1.status 200
Check 'the same seed twice: the same order' (Ids $a1) (Ids $a2)
Check 'meta.seed is the seed sent' $a1.json.meta.seed 'abc'
Check 'the pagination is still there' ($null -ne $a1.json.meta.pagination.total) $true
Check 'the total is the same as for newest' $a1.json.meta.pagination.total $full.Count
Check 'a sent seed: no no-store header' ($a1.headers['Cache-Control'] -like '*no-store*') $false

# ---- 2. another seed = another order ----
$x = Call '/products?sort=random&seed=xyz&limit=50'
Check 'seed abc and xyz: different orders' ((Ids $a1) -ne (Ids $x)) $true
Check 'but the same products (all pages)' ((@(AllItems 'sort=random&seed=xyz') | ForEach-Object { $_.id } | Sort-Object) -join ',') $fullIds
Check 'random is not the newest order' ((Ids $a1) -ne (($full | Select-Object -First 50 | ForEach-Object { $_.id }) -join ',')) $true

# ---- 3. stable pages ----
$limit = 7
$pages = [int][Math]::Ceiling($full.Count / $limit)
$seen = @()
for ($p = 1; $p -le $pages; $p++) { $seen += @((Call "/products?sort=random&seed=abc&limit=$limit&page=$p").json.data | ForEach-Object { $_.id }) }
Check 'pages of one seed: no duplicates' (@($seen | Sort-Object -Unique).Count) $seen.Count
Check 'pages of one seed: together the full set' (($seen | Sort-Object) -join ',') $fullIds
$p1 = @((Call '/products?sort=random&seed=abc&limit=5&page=1').json.data | ForEach-Object { $_.id })
$p2 = @((Call '/products?sort=random&seed=abc&limit=5&page=2').json.data | ForEach-Object { $_.id })
Check 'page 1 + page 2 = the first 10 of the long list' (($p1 + $p2) -join ',') ((@($a1.json.data) | Select-Object -First 10 | ForEach-Object { $_.id }) -join ',')
Check 'page 2 repeats nothing of page 1' @($p2 | Where-Object { $p1 -contains $_ }).Count 0

# ---- 4. no seed: the server picks one ----
$n = Call '/products?sort=random&limit=5'
Check 'no seed: 200' $n.status 200
Check 'meta.seed is 12 hex characters' ($n.json.meta.seed -cmatch '^[a-f0-9]{12}$') $true
Check 'a server seed is not cached (no-store)' ($n.headers['Cache-Control'] -like '*no-store*') $true
$again = Call "/products?sort=random&limit=5&seed=$($n.json.meta.seed)"
Check 'sending meta.seed back gives the same page' (Ids $again) (Ids $n)
Check 'other sorts have no meta.seed' ($null -eq (Call '/products?sort=newest&limit=5').json.meta.PSObject.Properties['seed']) $true
Check 'a seed with another sort is ignored' (Ids (Call '/products?sort=newest&seed=abc&limit=10')) (Ids (Call '/products?sort=newest&limit=10'))

# ---- 5. bad seeds ----
Check 'seed "bad seed!": 400' (Call '/products?sort=random&seed=bad%20seed!').status 400
Check 'seed with a quote: 400' (Call "/products?sort=random&seed=abc'--").status 400
Check 'seed of 33 characters: 400' (Call "/products?sort=random&seed=$('a' * 33)").status 400
Check 'empty seed: 400' (Call '/products?sort=random&seed=').status 400
Check 'seed of 32 characters: 200' (Call "/products?sort=random&seed=$('a' * 32)").status 200
Check 'unknown sort: 400' (Call '/products?sort=shuffle').status 400

# ---- 6. filters and card prices work the same ----
$avail = @(AllItems 'sort=random&seed=abc&availableOnly=true')
$availNewest = @(AllItems 'sort=newest&availableOnly=true')
Check 'availableOnly: no out-of-stock card' @($avail | Where-Object { $_.availability -eq 'OUT_OF_STOCK' }).Count 0
Check 'availableOnly: the same products as with newest' (($avail | ForEach-Object { $_.id } | Sort-Object) -join ',') (($availNewest | ForEach-Object { $_.id } | Sort-Object) -join ',')
$hidden = @($full | Where-Object { $_.availability -eq 'OUT_OF_STOCK' }).Count
Check 'availableOnly hides exactly the out-of-stock products' $avail.Count ($full.Count - $hidden)
Check 'availableOnly hides the sold-out product' @($avail | Where-Object { $_.id -eq $soldOut.id }).Count 0
Check 'without availableOnly it is listed' @(@(AllItems 'sort=random&seed=abc') | Where-Object { $_.id -eq $soldOut.id }).Count 1
$priceOf = @{}
foreach ($c in $full) { $priceOf[$c.id] = "$($c.lowestPrice)/$($c.highestPrice)/$($c.shopCount)/$($c.bestListingId)" }
Check 'random cards: the same lowest price, shop count and best listing' @(@($a1.json.data) | Where-Object { $priceOf[$_.id] -ne "$($_.lowestPrice)/$($_.highestPrice)/$($_.shopCount)/$($_.bestListingId)" }).Count 0
$cat = @(AllItems 'sort=random&seed=abc&category=laptops')
$catNewest = @(AllItems 'sort=newest&category=laptops')
Check 'category filter: the same products' (($cat | ForEach-Object { $_.id } | Sort-Object) -join ',') (($catNewest | ForEach-Object { $_.id } | Sort-Object) -join ',')
$qr = @(AllItems 'sort=random&seed=abc&q=galaxy&maxPrice=60000')
$qn = @(AllItems 'sort=newest&q=galaxy&maxPrice=60000')
Check 'search + price filter: the same products' (($qr | ForEach-Object { $_.id } | Sort-Object) -join ',') (($qn | ForEach-Object { $_.id } | Sort-Object) -join ',')

# restore the sold-out listings
foreach ($x in $restore) {
    Call "/shops/$($x.shopId)/listings/$($x.id)" 'PATCH' $x.token @{ availability = $x.availability; stockQty = $x.stockQty } | Out-Null
}
Check 'cleanup: the product is available again' @(@(AllItems 'sort=newest&availableOnly=true') | Where-Object { $_.id -eq $soldOut.id }).Count 1

Write-Host ''
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
