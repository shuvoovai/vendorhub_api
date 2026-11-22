# test-tolets.ps1 (shop to-let: public submissions, spam protection, admin approval, public list)
# Run from the project root on FRESH seed data while "npm run dev" is running: the per-IP limit
# (3 saved requests per hour) is counted in the database, so run "node --env-file=.env prisma/seed.js"
# (or run-all-tests.ps1, which reseeds) before running this again.
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
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; json = ($r.Content | ConvertFrom-Json); raw = $r.Content; headers = $r.Headers } }
    catch { if ($_.Exception.Response) { return @{ status = [int]$_.Exception.Response.StatusCode; json = $null } } return @{ status = 0; json = $null } }
}
function Login($email) {
    $r = Call 'POST' '/auth/login' $null @{ email = $email; password = 'Password123!' }
    if ($r.status -ne 200) { Write-Host "Login failed for $email" -ForegroundColor Red; exit 1 }
    return $r.json.data.accessToken
}
function Need($value, $what) { if (-not $value) { Write-Host "STOP: $what not found" -ForegroundColor Red; exit 1 } }
function Public { return , @((Call 'GET' '/tolets?limit=24' $null $null).json.data | Where-Object { $_ }) }
function AdminCount($status) { return (Call 'GET' "/admin/tolets?status=$status" $admin $null).json.meta.pagination.total }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$owner = Login 'owner1@vendorshub.test'
$next = (Get-Date).AddDays(10).ToString('yyyy-MM-dd')
function NewTolet($title, $phone) {
    return @{ type = 'SHOP'; title = $title; marketName = 'Bashundhara City'; floor = 'Level 4'; area = 'Panthapath'
        address = 'Shop 4-21, Bashundhara City, Panthapath, Dhaka'; rent = 45000; advance = 200000; sizeSqft = 220
        availableFrom = $next; contactName = 'Karim Ahmed'; contactPhone = $phone; description = "Corner shop near the escalator.`nGood foot traffic." }
}
Need ((Call 'GET' '/tolets' $null $null).status -eq 200) 'the to-let list'
Check 'fresh seed: no pending requests' (AdminCount 'PENDING') 0

# ---- 1. validation (nothing is saved) ----
$base1 = NewTolet 'Corner shop for rent' '01812345678'
$cases = @(
    @('unknown type FLAT', 'type', 'FLAT'), @('title too short', 'title', 'Shop'), @('title with HTML', 'title', '<b>Big shop</b> here'),
    @('invalid phone', 'contactPhone', '0181234567'), @('rent below 100', 'rent', 50), @('rent not a number', 'rent', 'cheap'),
    @('negative advance', 'advance', -1), @('size 0', 'sizeSqft', 0), @('date in the past', 'availableFrom', '2020-01-01'),
    @('date over a year ahead', 'availableFrom', (Get-Date).AddYears(2).ToString('yyyy-MM-dd')), @('bad date format', 'availableFrom', '10/12/2026'),
    @('impossible date', 'availableFrom', ((Get-Date).AddMonths(1).ToString('yyyy-MM') + '-31x')), @('area too short', 'area', 'P'),
    @('unknown key status', 'status', 'APPROVED'), @('unknown key userId', 'userId', '00000000-0000-4000-8000-000000000000'),
    @('description over 1000', 'description', ('d' * 1001))
)
foreach ($c in $cases) {
    $b = $base1.Clone(); $b[$c[1]] = $c[2]
    Check "$($c[0]): 400" (Call 'POST' '/tolets' $null $b).status 400
}
$miss = $base1.Clone(); $miss.Remove('contactName')
Check 'missing contactName: 400' (Call 'POST' '/tolets' $null $miss).status 400
Check 'nothing was saved by invalid requests' (AdminCount 'PENDING') 0

# ---- 2. honeypot ----
$bot = $base1.Clone(); $bot.website = 'http://spam.example'
$r = Call 'POST' '/tolets' $null $bot
Check 'honeypot: looks like success (201)' $r.status 201
Check 'honeypot: says PENDING' $r.json.data.status 'PENDING'
Check 'honeypot: nothing saved' (AdminCount 'PENDING') 0

# ---- 3. a guest submits; approval makes it public ----
$r = Call 'POST' '/tolets' $null $base1
Check 'guest submits: 201' $r.status 201
Check 'answer is only id + status' (@($r.json.data.PSObject.Properties).Count) 2
Check 'status PENDING' $r.json.data.status 'PENDING'
$aId = $r.json.data.id
Check 'pending is NOT public' (@(Public | Where-Object { $_.id -eq $aId }).Count) 0
Check 'public list has a short cache' ([string](Call 'GET' '/tolets' $null $null).headers['Cache-Control']) 'public, max-age=60'
Check 'admins were notified' (@((Call 'GET' '/notifications?limit=50' $admin $null).json.data | Where-Object { $_.type -eq 'TOLET_NEW' }).Count -ge 1) $true

Check 'non-admin: GET /admin/tolets 403' (Call 'GET' '/admin/tolets' $cust $null).status 403
Check 'non-admin: PATCH 403' (Call 'PATCH' "/admin/tolets/$aId" $owner @{ status = 'APPROVED' }).status 403
Check 'guest: GET /admin/tolets 401' (Call 'GET' '/admin/tolets' $null $null).status 401
Check 'bad id: 400' (Call 'PATCH' '/admin/tolets/not-a-uuid' $admin @{ status = 'APPROVED' }).status 400
Check 'review status PENDING: 400' (Call 'PATCH' "/admin/tolets/$aId" $admin @{ status = 'PENDING' }).status 400
$pend = @((Call 'GET' '/admin/tolets?status=PENDING' $admin $null).json.data)
Check 'admin sees the pending request' (@($pend | Where-Object { $_.id -eq $aId }).Count) 1
Check 'guest submission has no submitter' ($null -eq @($pend | Where-Object { $_.id -eq $aId })[0].submitter) $true
$ap = Call 'PATCH' "/admin/tolets/$aId" $admin @{ status = 'APPROVED' }
Check 'admin approves' $ap.status 200
$days = ([datetime]$ap.json.data.expiresAt - (Get-Date)).TotalDays
Check 'expires in about 60 days' (($days -gt 59) -and ($days -le 60.1)) $true
Check 'approving again: 409' (Call 'PATCH' "/admin/tolets/$aId" $admin @{ status = 'APPROVED' }).status 409
$pub = @(Public | Where-Object { $_.id -eq $aId })
Check 'approved is public' $pub.Count 1
$item = $pub[0]
Check 'availableFrom is YYYY-MM-DD' $item.availableFrom $next
foreach ($f in @('userId', 'submitterIpHash', 'reviewedById', 'reviewedBy', 'rejectionReason', 'submitter', 'expiresAt')) {
    Check "public item has no $f" ($null -eq $item.PSObject.Properties[$f]) $true
}
Check 'line break in description kept' ($item.description -match "`n") $true
Check 'type filter' (@((Call 'GET' '/tolets?type=SHOP' $null $null).json.data | Where-Object { $_.id -eq $aId }).Count) 1
Check 'other type hides it' (@((Call 'GET' '/tolets?type=KIOSK' $null $null).json.data | Where-Object { $_.id -eq $aId }).Count) 0
Check 'area filter (case-insensitive)' (@((Call 'GET' '/tolets?area=panthapath' $null $null).json.data | Where-Object { $_.id -eq $aId }).Count) 1
Check 'limit 25: 400' (Call 'GET' '/tolets?limit=25' $null $null).status 400
Check 'type FLAT in the filter: 400' (Call 'GET' '/tolets?type=FLAT' $null $null).status 400

# ---- 4. a logged-in customer submits; rejection ----
$r = Call 'POST' '/tolets' $cust (NewTolet 'Kiosk space on the ground floor' '01912345678')
Check 'logged-in customer submits: 201' $r.status 201
$bId = $r.json.data.id
$mine = @((Call 'GET' '/me/tolets' $cust $null).json.data)
Check '/me/tolets shows it' (@($mine | Where-Object { $_.id -eq $bId }).Count) 1
Check '/me/tolets needs login' (Call 'GET' '/me/tolets' $null $null).status 401
Check 'admin sees the submitter' ([bool](@((Call 'GET' '/admin/tolets?status=PENDING' $admin $null).json.data | Where-Object { $_.id -eq $bId })[0].submitter.email)) $true
Check 'reject without reason: 400' (Call 'PATCH' "/admin/tolets/$bId" $admin @{ status = 'REJECTED' }).status 400
Check 'reject with reason' (Call 'PATCH' "/admin/tolets/$bId" $admin @{ status = 'REJECTED'; reason = 'Phone number did not answer' }).status 200
Check 'rejected is not public' (@(Public | Where-Object { $_.id -eq $bId }).Count) 0
Check 'the submitter sees the reason' (@((Call 'GET' '/me/tolets' $cust $null).json.data | Where-Object { $_.id -eq $bId })[0].rejectionReason) 'Phone number did not answer'
Check 'the submitter was notified' (@((Call 'GET' '/notifications?limit=50' $cust $null).json.data | Where-Object { $_.type -eq 'TOLET_REVIEWED' }).Count) 1
$logs = @((Call 'GET' '/admin/audit-logs?entityType=Tolet&limit=50' $admin $null).json.data | ForEach-Object { $_.action })
Check 'approval audited' ($logs -contains 'tolet.approved') $true
Check 'rejection audited' ($logs -contains 'tolet.rejected') $true

# ---- 5. expired approvals disappear ----
node --env-file=.env scripts/expire-tolet.mjs $aId | Out-Null
Check 'expired is not public' (@(Public | Where-Object { $_.id -eq $aId }).Count) 0

# ---- 6. IP rate limit: 3 saved requests per hour ----
$r = Call 'POST' '/tolets' $null (NewTolet 'Warehouse space near Tejgaon' '01512345678')
Check 'third request this hour: 201' $r.status 201
$cId = $r.json.data.id
$lim = Call 'POST' '/tolets' $null (NewTolet 'Showroom space in Gulshan' '01612345678')
Check 'fourth request this hour: 429' $lim.status 429
Check 'a logged-in user on the same connection: 429 too' (Call 'POST' '/tolets' $owner (NewTolet 'Food court stall' '01312345678')).status 429

# ---- 7. own listing removal ----
Check "someone else's to-let: 404" (Call 'DELETE' "/me/tolets/$bId" $owner $null).status 404
Check "a guest's to-let cannot be deleted by a user: 404" (Call 'DELETE' "/me/tolets/$cId" $cust $null).status 404
Check 'bad id: 400' (Call 'DELETE' '/me/tolets/abc' $cust $null).status 400
Check 'the owner deletes it' (Call 'DELETE' "/me/tolets/$bId" $cust $null).status 200
Check 'gone from /me/tolets' (@((Call 'GET' '/me/tolets' $cust $null).json.data | Where-Object { $_.id -eq $bId }).Count) 0

Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
