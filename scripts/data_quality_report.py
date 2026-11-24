"""Build a self-contained HTML data-quality report from the checks in SQL Server.

It runs qa.usp_data_quality (sql/06_data_quality.sql), reads the latest results of
qa.usp_reconcile (sql/04_reconcile.sql), the daily receipt counts and the load log, and
writes reports/data_quality_<date>.html. Only the Python standard library is used.

usage: python scripts/data_quality_report.py      (the uplift-sql container must be running)
"""
import datetime
import html
import json
import pathlib
import shlex
import statistics
import subprocess

CONTAINER = "uplift-sql"
REPORTS_DIR = pathlib.Path(__file__).resolve().parent.parent / "reports"


def run_sql(query):
    """Run T-SQL inside the SQL Server container and return what sqlcmd prints.
    The password comes from the container's own environment variable, so it is never stored here."""
    sqlcmd = ('/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b '
              '-d uplift -y 0 -Q ' + shlex.quote(query))          # -y 0: don't cut off long text
    result = subprocess.run(["docker", "exec", CONTAINER, "bash", "-c", sqlcmd],
                            capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(f"SQL failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def query_rows(select):
    """Run a SELECT and return its rows as a list of dicts.
    FOR JSON makes SQL Server return the whole result as one JSON text, which is easy to read here."""
    output = run_sql("SET NOCOUNT ON; "
                     f"DECLARE @json NVARCHAR(MAX) = ({select} FOR JSON PATH, INCLUDE_NULL_VALUES); "
                     "SELECT ISNULL(@json, '[]');")
    return json.loads(output[output.find("["): output.rfind("]") + 1])


def fmt(n):
    """1234567 -> '1,234,567'; blank for None."""
    return "" if n is None else f"{n:,.0f}"


def esc(text):
    return html.escape("" if text is None else str(text))


# ---------------------------------------------------------------- collect the data
run_sql("EXEC qa.usp_data_quality")                       # fresh run of the source-data checks

checks = query_rows("""
    SELECT section, check_name, found, out_of, status, explanation, example
    FROM qa.data_quality_results
    WHERE run_at = (SELECT MAX(run_at) FROM qa.data_quality_results)
    ORDER BY result_id""")

reconcile = query_rows("""
    SELECT check_name, expected, actual, passed, run_at
    FROM qa.reconcile_log
    WHERE run_at = (SELECT MAX(run_at) FROM qa.reconcile_log)
    ORDER BY reconcile_log_id""")

daily = query_rows("""
    SELECT sales_date, transactions, total_purchase
    FROM mart.daily_sales
    ORDER BY sales_date""")

loads = query_rows("""
    SELECT step, row_count, logged_at
    FROM ops.run_log
    WHERE run_log_id IN (SELECT MAX(run_log_id) FROM ops.run_log GROUP BY step)
    ORDER BY run_log_id""")

# ---------------------------------------------------------------- summary numbers
reconcile_passed = sum(1 for r in reconcile if r["passed"])
counts = {s: sum(1 for c in checks if c["status"] == s) for s in ("OK", "Info", "Warning")}
typical_day = statistics.median(d["transactions"] for d in daily)
busiest_day = max(d["transactions"] for d in daily)

# ---------------------------------------------------------------- build the HTML pieces
reconcile_rows = "".join(
    f"<tr><td>{'<span class=ok>&#10003;</span>' if r['passed'] else '<span class=bad>&#10007;</span>'}</td>"
    f"<td>{esc(r['check_name'])}</td><td class=n>{fmt(r['expected'])}</td><td class=n>{fmt(r['actual'])}</td></tr>"
    for r in reconcile)

check_sections = ""
for section in dict.fromkeys(c["section"] for c in checks):          # sections in their original order
    rows = ""
    for c in (c for c in checks if c["section"] == section):
        share = 100 * c["found"] / c["out_of"] if c["out_of"] else None
        pct = "" if share is None else "<0.1%" if 0 < share < 0.1 else f"{share:.1f}%"
        rows += (f"<tr><td><span class='badge {c['status'].lower()}'>{esc(c['status'])}</span></td>"
                 f"<td><b>{esc(c['check_name'])}</b><div class=expl>{esc(c['explanation'])}</div>"
                 f"<div class=ex>{esc(c['example'])}</div></td>"
                 f"<td class=n>{fmt(c['found'])}</td><td class=n>{esc(pct)}</td></tr>")
    check_sections += (f"<h3>{esc(section)}</h3><table><thead><tr><th>Status</th><th>Check</th>"
                       f"<th class=n>Found</th><th class=n>% of checked</th></tr></thead><tbody>{rows}</tbody></table>")

# receipts per day as simple CSS bars; days under 25% of a typical day are highlighted
bars = ""
for d in daily:
    low = d["transactions"] < 0.25 * typical_day
    height = max(8 if low else 1, round(100 * d["transactions"] / busiest_day))   # keep flagged days visible
    bars += (f"<div class='bar{' low' if low else ''}' style='height:{height}%' "
             f"title='{d['sales_date']}: {fmt(d['transactions'])} receipts'></div>")

load_rows = "".join(f"<tr><td>{esc(l['step'])}</td><td class=n>{fmt(l['row_count'])}</td>"
                    f"<td>{esc(l['logged_at'].replace('T', ' '))}</td></tr>" for l in loads)

generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Data quality report</title>
<style>
 body {{ font-family: Segoe UI, Arial, sans-serif; max-width: 1000px; margin: 32px auto; color: #252423; }}
 h1 {{ margin-bottom: 4px; }} h2 {{ margin-top: 36px; }} h3 {{ margin: 22px 0 6px; }}
 .sub {{ color: #605E5C; margin-top: 0; }}
 .tiles {{ display: flex; gap: 12px; margin: 20px 0; }}
 .tile {{ flex: 1; border: 1px solid #E1DFDD; border-radius: 6px; padding: 12px; }}
 .tile .l {{ color: #605E5C; font-size: 12px; }} .tile .v {{ font-size: 24px; font-weight: 600; }}
 table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
 th, td {{ padding: 7px 8px; border-bottom: 1px solid #EDEBE9; text-align: left; vertical-align: top; }}
 th {{ color: #605E5C; font-weight: 600; }} .n {{ text-align: right; white-space: nowrap; }}
 .expl {{ color: #484644; margin-top: 3px; }} .ex {{ color: #8A8886; font-size: 12px; margin-top: 2px; }}
 .badge {{ padding: 2px 8px; border-radius: 10px; font-size: 12px; font-weight: 600; }}
 .badge.ok {{ background: #DFF6DD; color: #107C10; }} .badge.info {{ background: #EFF6FC; color: #0F6CBD; }}
 .badge.warning {{ background: #FFF4CE; color: #8A5300; }}
 .ok {{ color: #107C10; font-weight: 700; }} .bad {{ color: #C50F1F; font-weight: 700; }}
 .chart {{ display: flex; align-items: flex-end; gap: 1px; height: 140px; border-bottom: 1px solid #C8C6C4; }}
 .bar {{ flex: 1; background: #118DFF; }} .bar.low {{ background: #F7630C; }}
 .axis {{ display: flex; justify-content: space-between; color: #605E5C; font-size: 12px; margin-top: 4px; }}
 .foot {{ color: #605E5C; font-size: 12px; margin-top: 32px; }}
</style></head><body>

<h1>Data quality report</h1>
<p class="sub">SMS campaign uplift data in SQL Server (database <b>uplift</b>). Generated {generated}.</p>

<div class="tiles">
 <div class="tile"><div class="l">Pipeline reconciliation</div><div class="v">{reconcile_passed} / {len(reconcile)} passed</div></div>
 <div class="tile"><div class="l">Source-data checks: OK</div><div class="v">{counts['OK']}</div></div>
 <div class="tile"><div class="l">Info</div><div class="v">{counts['Info']}</div></div>
 <div class="tile"><div class="l">Warnings</div><div class="v">{counts['Warning']}</div></div>
</div>

<h2>1. Did the pipeline load and summarise everything?</h2>
<p class="sub">From qa.usp_reconcile: each number is calculated two independent ways and must match.</p>
<table><thead><tr><th></th><th>Check</th><th class=n>Expected</th><th class=n>Actual</th></tr></thead>
<tbody>{reconcile_rows}</tbody></table>

<h2>2. Is the source data itself sensible?</h2>
<p class="sub">From qa.usp_data_quality: odd or contradictory values in the source files.
Warnings are not pipeline errors; they describe the data and how the analysis handles it.</p>
{check_sections}

<h2>3. Receipts per day</h2>
<p class="sub">Orange = under 25% of a typical day ({fmt(typical_day)} receipts). Hover a bar for the date.</p>
<div class="chart">{bars}</div>
<div class="axis"><span>{daily[0]['sales_date']}</span><span>{daily[-1]['sales_date']}</span></div>

<h2>4. Latest load</h2>
<table><thead><tr><th>Step</th><th class=n>Rows</th><th>When</th></tr></thead><tbody>{load_rows}</tbody></table>

<p class="foot">Built by scripts/data_quality_report.py from qa.usp_data_quality, qa.reconcile_log,
mart.daily_sales and ops.run_log.</p>
</body></html>"""

REPORTS_DIR.mkdir(exist_ok=True)
out_file = REPORTS_DIR / f"data_quality_{datetime.date.today():%Y-%m-%d}.html"
out_file.write_text(page, encoding="utf-8")
print(f"Wrote {out_file}")
