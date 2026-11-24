"""Aggregate the full purchases.csv (~45M product rows) into the two tables the Power BI model uses.

Same logic as the original Power Query steps:
  1. per (client, transaction): points received = max, points spent = -min (spent is stored negative),
     express received = max, express spent = -min, items = sum of product_quantity,
     purchase amount = max(purchase_sum) (purchase_sum repeats on every product row of a transaction)
  2. per client: sum of the transaction values            -> data/purchases_by_client.csv
  3. per calendar date: sum of transaction purchase amounts -> data/purchases_by_date.csv

usage: python prep_purchases.py [path\\to\\purchases.csv]
       (default: $UPLIFT_DATA_DIR/purchases.csv, or ~/Desktop/uplift/purchases.csv)
"""
import os, sys, time
import pandas as pd

DATA_DIR = os.environ.get("UPLIFT_DATA_DIR", os.path.join(os.path.expanduser("~"), "Desktop", "uplift"))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DATA_DIR, "purchases.csv")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(OUT, exist_ok=True)

cols = ["client_id", "transaction_id", "transaction_datetime", "regular_points_received",
        "express_points_received", "regular_points_spent", "express_points_spent",
        "purchase_sum", "product_quantity"]
num = {c: "float64" for c in cols[3:]}

t0, rows, parts = time.time(), 0, []
for chunk in pd.read_csv(SRC, usecols=cols, dtype={"client_id": str, "transaction_id": str, **num},
                         chunksize=5_000_000):
    rows += len(chunk)
    chunk["date"] = chunk["transaction_datetime"].str.slice(0, 10)
    g = chunk.groupby(["client_id", "transaction_id", "date"], sort=False).agg(
        pr=("regular_points_received", "max"), ps=("regular_points_spent", "min"),
        er=("express_points_received", "max"), es=("express_points_spent", "min"),
        qty=("product_quantity", "sum"), amt=("purchase_sum", "max"))
    parts.append(g)
    print(f"{rows:,} rows read, {time.time() - t0:,.0f}s", flush=True)

# a transaction can straddle two chunks: combine partial results (max/min/sum are associative)
trn = pd.concat(parts).groupby(level=[0, 1, 2], sort=False).agg(
    pr=("pr", "max"), ps=("ps", "min"), er=("er", "max"), es=("es", "min"),
    qty=("qty", "sum"), amt=("amt", "max")).reset_index()
trn["ps"], trn["es"] = -trn["ps"], -trn["es"]

client = trn.groupby("client_id", sort=True).agg(**{
    "Total Points Received": ("pr", "sum"), "Total Points Spent": ("ps", "sum"),
    "Total Express Received": ("er", "sum"), "Total Express Spent": ("es", "sum"),
    "Total Product Bought": ("qty", "sum"), "Total Purchase": ("amt", "sum"),
    "Transactions": ("transaction_id", "size")}).reset_index()
client.to_csv(os.path.join(OUT, "purchases_by_client.csv"), index=False)

daily = trn.groupby("date", sort=True).agg(**{"Total Date Purchase": ("amt", "sum")}).reset_index()
daily = daily.rename(columns={"date": "transaction_datetime"})
daily.to_csv(os.path.join(OUT, "purchases_by_date.csv"), index=False)

print(f"done: {rows:,} product rows, {len(trn):,} transactions, {len(client):,} clients, "
      f"{len(daily):,} days, total spend {trn['amt'].sum():,.2f}, {time.time() - t0:,.0f}s")
