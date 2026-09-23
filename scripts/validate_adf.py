#!/usr/bin/env python3
"""Offline consistency checks for the ADF resources and SQL migrations.

Checks:
  * every JSON file parses
  * linked-service, dataset, data-flow and pipeline references resolve
  * activity dependsOn and @activity('...') expressions reference real activities
  * stored procedures called by pipelines are defined in sql/migrations
  * SQL-loading pipelines write only to covid_staging (no direct production
    sink and no TRUNCATE pre-copy script) and follow the stage -> validate ->
    publish -> failure-audit pattern
  * copy mappings and data-flow sink columns match the staging datasets
  * generated ARM templates contain the same pipeline and dataset definitions
    as the authored JSON

Usage: python3 scripts/validate_adf.py   (exit code 1 on any failure)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
errors = []


def fail(msg):
    errors.append(msg)


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# 1. JSON parses
for path in glob.glob("**/*.json", recursive=True):
    try:
        load(path)
    except ValueError as exc:
        fail(f"{path}: invalid JSON ({exc})")

folders = {"LinkedServiceReference": "linkedService", "DatasetReference": "dataset",
           "DataFlowReference": "dataflow", "PipelineReference": "pipeline"}
names = {f: {os.path.basename(p)[:-5] for p in glob.glob(f"{f}/*.json")} for f in folders.values()}


def walk(obj, fn):
    if isinstance(obj, dict):
        fn(obj)
        for value in obj.values():
            walk(value, fn)
    elif isinstance(obj, list):
        for value in obj:
            walk(value, fn)


# 2. references resolve
for folder in names:
    for path in glob.glob(f"{folder}/*.json"):
        def check_ref(o, path=path):
            if o.get("type") in folders and "referenceName" in o:
                if o["referenceName"] not in names[folders[o["type"]]]:
                    fail(f"{path}: missing {o['type']} '{o['referenceName']}'")
        walk(load(path), check_ref)

# 3. activity dependencies and expressions
sql_text = "\n".join(open(p, encoding="utf-8").read() for p in sorted(glob.glob("sql/migrations/*.sql")))
defined_procs = {m.lower() for m in re.findall(r"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+([\w\.\[\]]+)", sql_text, re.I)}
defined_procs = {p.replace("[", "").replace("]", "") for p in defined_procs}


def activities(acts):
    for a in acts:
        yield a
        tp = a.get("typeProperties", {})
        for key in ("activities", "ifTrueActivities", "ifFalseActivities"):
            yield from activities(tp.get(key, []))


for path in glob.glob("pipeline/*.json"):
    pipe = load(path)
    acts = list(activities(pipe["properties"]["activities"]))
    act_names = {a["name"] for a in acts}
    text = json.dumps(pipe)
    for a in acts:
        for d in a.get("dependsOn", []):
            if d["activity"] not in act_names:
                fail(f"{path}: {a['name']} depends on unknown activity '{d['activity']}'")
        if a["type"] == "SqlServerStoredProcedure":
            proc = a["typeProperties"]["storedProcedureName"].replace("[", "").replace("]", "").lower()
            if proc not in defined_procs:
                fail(f"{path}: stored procedure {proc} not defined in sql/migrations")
    for ref in re.findall(r"activity\('([^']+)'\)", text):
        if ref not in act_names:
            fail(f"{path}: expression references unknown activity '{ref}'")

# 4. SQL-loading pipelines follow the staged pattern
STAGING = {"cases_and_deaths", "hospital_admissions_daily", "testing"}
for path in glob.glob("pipeline/pl_sqlize_*.json"):
    pipe = load(path)
    props = pipe["properties"]
    acts = {a["name"]: a for a in props["activities"]}
    copies = [a for a in acts.values() if a["type"] == "Copy"]
    for cp in copies:
        sink = cp["typeProperties"]["sink"]
        script = json.dumps(sink.get("preCopyScript", ""))
        if "TRUNCATE" in script.upper():
            fail(f"{path}: copy sink still runs TRUNCATE")
        for out in cp["outputs"]:
            ds = load(f"dataset/{out['referenceName']}.json")["properties"]
            if ds["typeProperties"].get("schema") != "covid_staging":
                fail(f"{path}: copy writes to {ds['typeProperties']} instead of covid_staging")
            staging_cols = {c["name"] for c in ds["schema"]}
            mappings = cp["typeProperties"].get("translator", {}).get("mappings")
            if mappings:
                for m in mappings:
                    if m["sink"]["name"] not in staging_cols:
                        fail(f"{path}: mapping sink column {m['sink']['name']} missing from staging dataset")
            add = [c["name"] for c in cp["typeProperties"]["source"].get("additionalColumns", [])]
            if "load_run_id" not in add:
                fail(f"{path}: copy does not stamp load_run_id")
    procs = [a["typeProperties"]["storedProcedureName"] for a in acts.values() if a["type"] == "SqlServerStoredProcedure"]
    for needed in ("usp_begin_load", "usp_validate_", "usp_publish_", "usp_record_load_failure"):
        if not any(needed in p for p in procs):
            fail(f"{path}: missing {needed} step")
    if props.get("concurrency") != 1:
        fail(f"{path}: pipeline concurrency must be 1")
    pub = acts.get("publish_snapshot")
    if not pub or pub["dependsOn"] != [{"activity": "validate_staged_snapshot", "dependencyConditions": ["Succeeded"]}]:
        fail(f"{path}: publish must depend only on successful validation")

# 5. data-flow sink columns match staging datasets
FLOW_SINKS = {("df_transform_cases_deaths", "selectForSink"): "ds_sql_staging_cases_and_deaths",
              ("df_transform_hospital_admissions", "selectDaily"): "ds_sql_staging_hospital_admissions_daily"}
for (flow, node), ds_name in FLOW_SINKS.items():
    script = "\n".join(load(f"dataflow/{flow}.json")["properties"]["typeProperties"]["scriptLines"])
    block = re.search(r"select\(mapColumn\(([^~]*?)\)\s*,\s*skipDuplicateMapInputs[^~]*~>\s*" + node, script, re.S)
    if not block:
        fail(f"{flow}: could not find select node {node}")
        continue
    cols = set()
    for item in block.group(1).split(","):
        item = item.strip()
        if item:
            cols.add(item.split("=")[0].strip())
    staging = {c["name"] for c in load(f"dataset/{ds_name}.json")["properties"]["schema"]} - {"load_run_id", "staged_at_utc"}
    if cols != staging:
        fail(f"{flow}.{node} columns {sorted(cols)} != {ds_name} columns {sorted(staging)}")

# 6. generated ARM templates match authored pipelines and datasets
arm_dir = next((d for d in ("covid-reporting-adf", "vishal-covid-reporting-adf") if os.path.isdir(d)), None)
if arm_dir:
    arm = load(f"{arm_dir}/ARMTemplateForFactory.json")
    arm_res = {(r["type"].split("/")[-1], r["name"].split("'/")[1].rstrip("')]")): r for r in arm["resources"]}

    def strip_normalization(o):
        if isinstance(o, dict):
            o = {k: strip_normalization(v) for k, v in o.items()
                 if not (k in ("parameters", "staging") and v == {})
                 and not (k == "datasetParameters" and isinstance(v, dict)
                          and all(x == {} for x in v.values()))}
            return o
        if isinstance(o, list):
            return [strip_normalization(v) for v in o]
        return o

    for kind, folder in (("pipelines", "pipeline"), ("datasets", "dataset")):
        for name in names[folder]:
            res = arm_res.get((kind, name))
            if res is None:
                fail(f"{arm_dir}: {kind[:-1]} {name} missing from ARMTemplateForFactory.json")
                continue
            src = strip_normalization(load(f"{folder}/{name}.json")["properties"])
            gen = strip_normalization(res["properties"])
            gen.pop("policy", None) if kind == "pipelines" and "policy" not in src else None
            if src != gen:
                fail(f"{arm_dir}: {kind[:-1]} {name} differs from authored JSON")
        for (k, n) in arm_res:
            if k == kind and n not in names[folder]:
                fail(f"{arm_dir}: {k[:-1]} {n} has no authored JSON")

if errors:
    print("\n".join(f"FAIL: {e}" for e in errors))
    sys.exit(1)
print("ADF validation passed: JSON, references, SQL-load pattern, mappings, ARM consistency.")
