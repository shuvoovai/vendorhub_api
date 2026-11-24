# test-tolet-inquiries.ps1 (visit requests for to-let listings: public submit, spam protection, admin workflow)
# Run from the project root on FRESH seed data while "npm run dev" is running: the per-IP limit
# (5 saved requests per hour) is counted in the database, so reseed (or use run-all-tests.ps1) before running again.
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
function MakeTolet($mode) { return ([string](node --env-file=.env scripts/make-test-tolet.mjs $mode)).Trim() }
function Inquiries($q) { return , @((Call 'GET' "/admin/tolet-inquiries$q" $admin $null).json.data | Where-Object { $_ }) }

try { Invoke-WebRequest 'http://localhost:4000/health' -UseBasicParsing | Out-Null }
catch { Write-Host 'The API is not running.' -ForegroundColor Red; exit 1 }

$admin = Login 'admin@vendorshub.test'
$cust = Login 'customer@vendorshub.test'
$okId = MakeTolet 'approved'
$pendId = MakeTolet 'pending'
$expId = MakeTolet 'expired'
$in3 = (Get-Date).AddDays(3).ToString('yyyy-MM-dd')
function NewInquiry { return @{ name = 'Nusrat Jahan'; phone = '01822333444'; preferredDate = $in3; preferredTime = 'AFTERNOON'; message = "Can I visit on Friday?`nAfter Jummah is best." } }
Check 'fresh seed: no inquiries' (Inquiries '').Count 0

# ---- 1. the public list no longer shows the contact ----
$pub = @((Call 'GET' '/tolets?limit=24' $null $null).json.data | Where-Object { $_.id -eq $okId })
Check 'approved test listing is public' $pub.Count 1
Check 'public item has no contactName' ($null -eq $pub[0].PSObject.Properties['contactName']) $true
Check 'public item has no contactPhone' ($null -eq $pub[0].PSObject.Properties['contactPhone']) $true
$adm = @((Call 'GET' '/admin/tolets?status=APPROVED&limit=100' $admin $null).json.data | Where-Object { $_.id -eq $okId })
Check 'admin list keeps contactPhone' $adm[0].contactPhone '01711000222'

# ---- 2. validation (nothing is saved) ----
$cases = @(
    @('name too short', 'name', 'N'), @('name with HTML', 'name', '<b>Nusrat</b>'), @('name over 80', 'name', ('n' * 81)),
    @('invalid phone', 'phone', '01222333444'), @('short phone', 'phone', '0182233344'),
    @('date in the past', 'preferredDate', (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')),
    @('date over 90 days ahead', 'preferredDate', (Get-Date).AddDays(95).ToString('yyyy-MM-dd')),
    @('bad date format', 'preferredDate', '12/10/2026'), @('impossible date', 'preferredDate', '2026-02-30'),
    @('unknown time NIGHT', 'preferredTime', 'NIGHT'), @('message over 500', 'message', ('m' * 501)),
    @('unknown key status', 'status', 'CLOSED')
)
foreach ($c in $cases) {
    $b = NewInquiry; $b[$c[1]] = $c[2]
    Check "$($c[0]): 400" (Call 'POST' "/tolets/$okId/inquiries" $null $b).status 400
}
$miss = NewInquiry; $miss.Remove('preferredTime')
Check 'missing preferredTime: 400' (Call 'POST' "/tolets/$okId/inquiries" $null $miss).status 400
Check 'bad tolet id: 400' (Call 'POST' '/tolets/not-a-uuid/inquiries' $null (NewInquiry)).status 400
Check 'unknown tolet: 404' (Call 'POST' '/tolets/00000000-0000-4000-8000-000000000000/inquiries' $null (NewInquiry)).status 404
Check 'pending tolet: 404' (Call 'POST' "/tolets/$pendId/inquiries" $null (NewInquiry)).status 404
Check 'expired tolet: 404' (Call 'POST' "/tolets/$expId/inquiries" $null (NewInquiry)).status 404
Check 'nothing saved so far' (Inquiries '').Count 0

# ---- 3. honeypot ----
$bot = NewInquiry; $bot.website = 'http://spam.example'
$r = Call 'POST' "/tolets/$okId/inquiries" $null $bot
Check 'honeypot: looks like success (201)' $r.status 201
Check 'honeypot: answer is only id' (@($r.json.data.PSObject.Properties).Count) 1
Check 'honeypot: nothing saved' (Inquiries '').Count 0

# ---- 4. a guest asks to visit ----
$r = Call 'POST' "/tolets/$okId/inquiries" $null (NewInquiry)
Check 'guest submits: 201' $r.status 201
Check 'answer is only id' (@($r.json.data.PSObject.Properties).Count) 1
$qId = $r.json.data.id
$today = Call 'POST' "/tolets/$okId/inquiries" $null (@{ name = 'Tanvir'; phone = '01922333444'; preferredDate = (Get-Date).ToString('yyyy-MM-dd'); preferredTime = 'MORNING' })
Check 'today, no message: 201' $today.status 201
$q2Id = $today.json.data.id

# ---- 5. admin list ----
Check 'customer: GET 403' (Call 'GET' '/admin/tolet-inquiries' $cust $null).status 403
Check 'guest: GET 401' (Call 'GET' '/admin/tolet-inquiries' $null $null).status 401
Check 'bad status filter: 400' (Call 'GET' '/admin/tolet-inquiries?status=OPEN' $admin $null).status 400
$all = Inquiries ''
Check 'admin sees both' $all.Count 2
Check 'newest first' $all[0].id $q2Id
$item = @($all | Where-Object { $_.id -eq $qId })[0]
Check 'name' $item.name 'Nusrat Jahan'
Check 'phone' $item.phone '01822333444'
Check 'preferredDate is YYYY-MM-DD' $item.preferredDate $in3
Check 'preferredTime' $item.preferredTime 'AFTERNOON'
Check 'line break in message kept' ($item.message -match "`n") $true
Check 'status NEW' $item.status 'NEW'
Check 'tolet contactPhone included' $item.tolet.contactPhone '01711000222'
Check 'tolet has 8 fields' (@($item.tolet.PSObject.Properties).Count) 8
Check 'no IP hash in the item' ($null -eq $item.PSObject.Properties['submitterIpHash']) $true
Check 'message null when not given' ($null -eq @($all | Where-Object { $_.id -eq $q2Id })[0].message) $true
Check 'status=NEW filter' (Inquiries '?status=NEW').Count 2
Check 'status=CLOSED filter' (Inquiries '?status=CLOSED').Count 0

# ---- 6. status changes ----
Check 'customer: PATCH 403' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $cust @{ status = 'CONTACTED' }).status 403
Check 'bad id: 400' (Call 'PATCH' '/admin/tolet-inquiries/abc' $admin @{ status = 'CONTACTED' }).status 400
Check 'unknown id: 404' (Call 'PATCH' '/admin/tolet-inquiries/00000000-0000-4000-8000-000000000000' $admin @{ status = 'CONTACTED' }).status 404
Check 'bad status: 400' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'DONE' }).status 400
Check 'extra key: 400' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'CONTACTED'; name = 'x' }).status 400
Check 'NEW -> NEW: 409' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'NEW' }).status 409
$u = Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'CONTACTED' }
Check 'NEW -> CONTACTED: 200' $u.status 200
Check 'answer shows CONTACTED' $u.json.data.status 'CONTACTED'
Check 'CONTACTED -> NEW: 409' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'NEW' }).status 409
Check 'CONTACTED -> CONTACTED: 409' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'CONTACTED' }).status 409
Check 'CONTACTED -> CLOSED: 200' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'CLOSED' }).status 200
Check 'CLOSED -> CONTACTED: 409' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'CONTACTED' }).status 409
Check 'CLOSED -> NEW: 200' (Call 'PATCH' "/admin/tolet-inquiries/$qId" $admin @{ status = 'NEW' }).status 200
Check 'NEW -> CLOSED: 200' (Call 'PATCH' "/admin/tolet-inquiries/$q2Id" $admin @{ status = 'CLOSED' }).status 200
Check 'status=CLOSED filter now 1' (Inquiries '?status=CLOSED').Count 1
$logs = @((Call 'GET' '/admin/audit-logs?entityType=ToletInquiry&limit=50' $admin $null).json.data)
Check 'every change audited' $logs.Count 4
Check 'audit has no phone' (($logs | ConvertTo-Json -Depth 6) -match '01822333444') $false

# ---- 7. IP rate limit: 5 saved per hour ----
foreach ($i in 3..5) { Check "request $i this hour: 201" (Call 'POST' "/tolets/$okId/inquiries" $null (NewInquiry)).status 201 }
Check 'sixth request this hour: 429' (Call 'POST' "/tolets/$okId/inquiries" $null (NewInquiry)).status 429
Check 'still 5 saved' (Inquiries '').Count 5

# ---- 8. deleting the listing removes its inquiries ----
node --env-file=.env scripts/make-test-tolet.mjs delete $okId | Out-Null
Check 'cascade delete' (Inquiries '').Count 0
node --env-file=.env scripts/make-test-tolet.mjs delete $pendId | Out-Null
node --env-file=.env scripts/make-test-tolet.mjs delete $expId | Out-Null

Write-Host ''
Write-Host "Passed: $($script:pass)   Failed: $($script:fail)"
