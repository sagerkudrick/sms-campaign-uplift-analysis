# Run T-SQL inside the uplift-sql container.
#   .\scripts\sqlcmd.ps1 -Query "EXEC rpt.usp_campaign_summary"
#   .\scripts\sqlcmd.ps1 -File /sql/01_database_and_tables.sql
#   .\scripts\sqlcmd.ps1 -Query "EXEC qa.usp_reconcile" -Extra "-W", "-s '|'"
# The sa password is read from the container's own environment, so it never appears on this machine's command line.
# Arguments are wrapped in bash single quotes: Windows PowerShell 5.1 mangles embedded double quotes
# when it passes them to native programs such as docker.
param(
    [string]$Query,
    [string]$File,
    [string]$Database = "uplift",
    [string[]]$Extra = @()
)
function ConvertTo-BashQuoted([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }

$target = if ($File) { "-i " + (ConvertTo-BashQuoted $File) } else { "-Q " + (ConvertTo-BashQuoted $Query) }
$cmd = "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P `$MSSQL_SA_PASSWORD -C -b -d $Database $target $($Extra -join ' ')"
$ErrorActionPreference = "Continue"   # sqlcmd prints messages on stderr; failure is judged by the exit code
docker exec uplift-sql bash -c $cmd 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE)" }
