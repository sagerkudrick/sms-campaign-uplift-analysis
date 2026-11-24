# Build everything from scratch: start SQL Server, create the tables and procedures,
# load the CSVs, build the summary tables and run the data checks.
# Needs: Docker Desktop running, .env with MSSQL_SA_PASSWORD, the CSVs in Desktop\uplift
# (or the folder in $env:UPLIFT_DATA_DIR), and Python (for prep_purchases.py and the line count).
# Takes about 10 minutes, mostly loading the 4.4 GB purchases.csv.

$ErrorActionPreference = "Continue"   # docker and sqlcmd print progress on stderr; failures are caught by exit code
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$sql = Join-Path $PSScriptRoot "sqlcmd.ps1"
$dataDir = if ($env:UPLIFT_DATA_DIR) { $env:UPLIFT_DATA_DIR } else { Join-Path $env:USERPROFILE "Desktop\uplift" }

Write-Host "Starting SQL Server..."
docker compose up -d 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }

Write-Host "Waiting for SQL Server to accept connections..."
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    try { & $sql -Database master -Query "SELECT 1" | Out-Null; $ready = $true } catch { Start-Sleep -Seconds 3 }
}
if (-not $ready) { throw "SQL Server did not start" }

Write-Host "Creating tables and procedures..."
& $sql -Database master -File /sql/01_database_and_tables.sql
& $sql -File /sql/02_load_raw.sql
& $sql -File /sql/03_build_marts.sql
& $sql -File /sql/04_reconcile.sql
& $sql -File /sql/05_reporting.sql
& $sql -File /sql/06_data_quality.sql

Write-Host "Loading the CSVs..."
& $sql -Query "EXEC ops.usp_load_raw"

Write-Host "Building the summary tables..."
& $sql -Query "EXEC mart.usp_build_marts"

Write-Host "Running the data checks..."
if (-not (Test-Path (Join-Path $root "data\purchases_by_client.csv"))) {
    python (Join-Path $root "prep_purchases.py") (Join-Path $dataDir "purchases.csv")
}
& $sql -Query "EXEC qa.usp_load_python_output"
# Count the lines of purchases.csv on Windows (reading it through Docker is far slower); minus 1 for the header
$expected = [int64](python (Join-Path $PSScriptRoot "count_lines.py") (Join-Path $dataDir "purchases.csv")) - 1
& $sql -Query "EXEC qa.usp_reconcile @expected_purchase_rows = $expected" -Extra "-W", "-s '|'"

Write-Host "Writing the data-quality report..."
python (Join-Path $PSScriptRoot "data_quality_report.py")

Write-Host "Done. Try: .\scripts\sqlcmd.ps1 -Query `"EXEC rpt.usp_uplift_by_segment @segment = 'spend'`""
