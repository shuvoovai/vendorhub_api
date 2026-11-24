# test-env.ps1: dot-source this BEFORE seeding or starting a server for tests:   . .\test-env.ps1
# Points this shell at the separate test database (vh_test) and test upload folder, so the tests never
# touch the real database (vendors_hub) or the real uploads. Environment variables win over .env, because
# Node's --env-file never overrides a variable that is already set.
# One-time setup:  docker exec vendors-hub-db createdb -U vendors vh_test
#                  docker exec vendors-hub-db psql -U vendors -d vh_test -c "CREATE EXTENSION IF NOT EXISTS vector"
#                  then (with this file loaded) npx prisma migrate deploy
$env:DATABASE_URL = 'postgresql://vendors:vendors_pass@localhost:5433/vh_test?schema=public'
$env:UPLOAD_DIR = './uploads-test'
$env:SEARCH_IMAGE_MODE = 'mock'
$env:TRYON_MODE = 'mock'
$env:MAIL_MODE = 'log'
$env:AUTO_VERIFY_EMAIL_DOMAINS = 'vendorshub.test'
$env:UPLOAD_RATE_LIMIT_MAX = '60' # the banner suites upload more than 20 files in 10 minutes
if ($env:DATABASE_URL -notmatch '/vh_test\?') { throw 'test-env.ps1: DATABASE_URL is not the test database' }
Write-Host 'Test environment: database vh_test, uploads ./uploads-test (the real data is not touched)' -ForegroundColor Cyan
