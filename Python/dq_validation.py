# =========================================================
# ENTERPRISE DATA QUALITY VALIDATION – EMR VERSION
# =========================================================

import sys
import yaml
import pandas as pd
import boto3
import os
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, sha2, concat_ws, coalesce, lit

# ---------------------------------------------------------
# ARGUMENT VALIDATION
# ---------------------------------------------------------
if len(sys.argv) != 2:
    raise ValueError("Usage: spark-submit dq_validation.py <TABLE_NAME>")

TABLE_NAME = sys.argv[1]

# ---------------------------------------------------------
# S3 LOCATIONS (LOCKED)
# ---------------------------------------------------------
CONFIG_BUCKET = "dq-config-bucket"
OUTPUT_BUCKET = "dq-output-bucket"

CONFIG_KEY = f"{TABLE_NAME}_config.yml"
LOCAL_CONFIG = f"/tmp/{TABLE_NAME}_config.yml"
LOCAL_EXCEL = f"/tmp/{TABLE_NAME}_validation_doc.xlsx"
OUTPUT_KEY = f"{TABLE_NAME}_validation_doc.xlsx"

# ---------------------------------------------------------
# DOWNLOAD CONFIG FROM S3
# ---------------------------------------------------------
s3 = boto3.client("s3")
s3.download_file(CONFIG_BUCKET, CONFIG_KEY, LOCAL_CONFIG)

# ---------------------------------------------------------
# LOAD CONFIG
# ---------------------------------------------------------
with open(LOCAL_CONFIG) as f:
    cfg = yaml.safe_load(f)

# ---------------------------------------------------------
# SPARK SESSION
# ---------------------------------------------------------
spark = SparkSession.builder.enableHiveSupport().getOrCreate()

# ---------------------------------------------------------
# YAML VALIDATION (FAIL FAST)
# ---------------------------------------------------------
def validate_yaml(cfg):
    for key in ["db2_connection", "tables", "output"]:
        if key not in cfg:
            raise ValueError(f"YAML ERROR: Missing {key}")

    if len(cfg["tables"]) != 1:
        raise ValueError("Exactly ONE table config expected per file")

    t = cfg["tables"][0]

    for k in ["table_id", "enabled", "source_db2", "source_glue", "keys", "thresholds"]:
        if k not in t:
            raise ValueError(f"YAML ERROR: Missing {k}")

    if t["table_id"] != TABLE_NAME:
        raise ValueError("TABLE_NAME does not match config table_id")

    if t["source_db2"]["read_type"] != "QUERY":
        raise ValueError("Only QUERY mode allowed for DB2")

    if t["source_glue"]["read_type"] != "QUERY":
        raise ValueError("Only QUERY mode allowed for Glue")

validate_yaml(cfg)

# ---------------------------------------------------------
# READERS
# ---------------------------------------------------------
def read_db2(spark, conn, src):
    return (
        spark.read.format("jdbc")
        .option("url", conn["url"])
        .option("dbtable", f"({src['query']}) X")
        .option("user", conn["user"])
        .option("password", conn["password"])
        .option("driver", conn["driver"])
        .load()
    )

def read_glue(spark, src):
    return spark.sql(src["query"])

# ---------------------------------------------------------
# VALIDATION FUNCTIONS
# ---------------------------------------------------------
def schema_mismatch(df1, df2):
    s1 = {f.name: f.dataType.simpleString() for f in df1.schema}
    s2 = {f.name: f.dataType.simpleString() for f in df2.schema}
    return [c for c in set(s1) | set(s2) if s1.get(c) != s2.get(c)]

def null_stats(df):
    total = df.count()
    nulls = sum(df.filter(col(c).isNull()).count() for c in df.columns)
    pct = (nulls / (total * len(df.columns))) * 100 if total > 0 else 0
    return nulls, pct

def add_row_hash(df):
    cols = sorted(df.columns)
    return df.withColumn(
        "row_hash",
        sha2(
            concat_ws(
                "||",
                *[coalesce(col(c).cast("string"), lit("NULL")) for c in cols]
            ),
            256
        )
    )

# ---------------------------------------------------------
# EXECUTION
# ---------------------------------------------------------
t = cfg["tables"][0]

db2_df = read_db2(spark, cfg["db2_connection"], t["source_db2"])
glue_df = read_glue(spark, t["source_glue"])

db2_count = db2_df.count()
glue_count = glue_df.count()
row_diff = abs(db2_count - glue_count)

schema_diff = schema_mismatch(db2_df, glue_df)
null_cnt, null_pct = null_stats(db2_df)

db2_h = add_row_hash(db2_df)
glue_h = add_row_hash(glue_df)

keys = t["keys"]["composite"]

hash_diff_df = (
    db2_h.alias("d1")
    .join(glue_h.alias("d2"), keys, "inner")
    .filter(col("d1.row_hash") != col("d2.row_hash"))
)

hash_mismatch = hash_diff_df.count()

# ---------------------------------------------------------
# STATUS DECISION
# ---------------------------------------------------------
status = "PASS"
if (
    row_diff > t["thresholds"]["FAIL"]["row_diff"] or
    len(schema_diff) > t["thresholds"]["FAIL"]["schema_mismatch"] or
    hash_mismatch > t["thresholds"]["FAIL"]["hash_mismatch"]
):
    status = "FAIL"
elif null_pct > t["thresholds"]["WARN"]["null_pct"]:
    status = "WARN"

# ---------------------------------------------------------
# EXCEL GENERATION (LOCAL)
# ---------------------------------------------------------
metrics_df = pd.DataFrame([[
    TABLE_NAME, db2_count, glue_count, row_diff,
    len(schema_diff), null_pct, hash_mismatch, status
]], columns=[
    "table_id", "db2_rows", "glue_rows", "row_diff",
    "schema_mismatch", "null_pct", "hash_mismatch", "status"
])

summary_df = pd.DataFrame([
    [TABLE_NAME, "DB2", db2_count, len(db2_df.columns)],
    [TABLE_NAME, "GLUE", glue_count, len(glue_df.columns)]
], columns=["table_id", "source", "rows", "columns"])

with pd.ExcelWriter(LOCAL_EXCEL, engine="xlsxwriter") as writer:
    wb = writer.book
    header = wb.add_format({"bold": True, "bg_color": "#305496", "font_color": "white"})

    metrics_df.to_excel(writer, "VALIDATION_METRICS", index=False)
    writer.sheets["VALIDATION_METRICS"].visibility = "hidden"

    dash = wb.add_worksheet("DASHBOARD")
    dash.write("C2", "DATA QUALITY DASHBOARD", header)
    dash.write_row("C4", ["Total", "PASS", "FAIL", "DQ %"], header)
    dash.write_formula("C5", "=1")
    dash.write_formula("D5", '=COUNTIF(VALIDATION_METRICS!H:H,"PASS")')
    dash.write_formula("E5", '=COUNTIF(VALIDATION_METRICS!H:H,"FAIL")')
    dash.write_formula("F5", "=D5/C5*100")

    summary_df.to_excel(writer, "SUMMARY", startcol=2, index=False)
    writer.sheets["SUMMARY"].write("C1", "TABLE SUMMARY", header)

    metrics_df[["table_id", "status"]].to_excel(writer, "FINAL_SUMMARY", index=False)

# ---------------------------------------------------------
# UPLOAD EXCEL TO S3
# ---------------------------------------------------------
s3.upload_file(LOCAL_EXCEL, OUTPUT_BUCKET, OUTPUT_KEY)

print(f"✅ Validation completed. Excel uploaded to s3://{OUTPUT_BUCKET}/{OUTPUT_KEY}")
