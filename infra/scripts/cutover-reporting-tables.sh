#!/usr/bin/env bash
# Swaps validated tables in for dfo_reporting views, and puts the views back.
# BigQuery cannot replace a view with a table in one statement, and the
# analytics dbt build refuses to drop a view (its refuse_to_replace_a_view
# pre-hook), so each name moves here first (infra/dfo-prod/telemetry/README.md,
# "Moving a view to dbt"):
#
#   infra/scripts/cutover-reporting-tables.sh swap <staging dataset> <name>...
#   infra/scripts/cutover-reporting-tables.sh restore <name>...
#
# swap, for each name that is a view in $DATASET:
# 1. saves the view's query and every authorised-view entry naming it, on any
#    dataset in $PROJECT, to $BACKUP/<name>.json;
# 2. copies <staging dataset>.<name> to $DATASET.<name>__swap and stops unless
#    the copy has the view's column names, order and types;
# 3. drops the view and renames the copy to <name>. The two calls are
#    metadata changes, so the name is missing for about a second. If the
#    rename fails, the copy stays as <name>__swap: rerun swap, which
#    finishes the rename, or run restore.
# A name that is already a table is left alone.
#
# restore, for each name with a backup: renames the table at <name>, if any,
# to <name>__rolled_back, recreates the view from the backup and adds back
# each saved authorised-view entry missing from its dataset.
#
# Environment: PROJECT (default prod-fin-observatory), DATASET (default
# dfo_reporting), BACKUP (default ./reporting-cutover-backup). Run it as an
# account that can update dataset access, such as a project owner.
set -euo pipefail

PROJECT="${PROJECT:-prod-fin-observatory}"
DATASET="${DATASET:-dfo_reporting}"
BACKUP="${BACKUP:-./reporting-cutover-backup}"

usage() {
    echo "usage: $0 swap <staging dataset> <name>... | $0 restore <name>..." >&2
    exit 2
}

bqq() {
    bq --quiet --project_id="$PROJECT" "$@"
}

# kind <dataset> <name>: prints TABLE, VIEW or none.
kind() {
    local meta
    if meta="$(bqq show --format=json "$PROJECT:$1.$2" 2>/dev/null)"; then
        python3 -c 'import json,sys; print(json.loads(sys.argv[1])["type"])' "$meta"
    else
        echo none
    fi
}

# columns <dataset> <name>: prints the relation's columns in order with types.
columns() {
    bqq query --location=EU --use_legacy_sql=false --format=csv --max_rows=1 \
        "SELECT STRING_AGG(column_name || ' ' || data_type, ', ' ORDER BY ordinal_position)
         FROM \`$PROJECT.$1.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name = '$2'" | tail -n +2
}

# save <name>: writes the view's query and description, and the
# authorised-view entries that name it on any dataset in $PROJECT, to
# $BACKUP/<name>.json.
save() {
    python3 - "$PROJECT" "$DATASET" "$1" "$BACKUP/$1.json" <<'PY'
import json
import subprocess
import sys

project, dataset, name, path = sys.argv[1:5]


def bq(*args):
    out = subprocess.run(
        ["bq", "--quiet", "--format=json", f"--project_id={project}", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


view = bq("show", f"{project}:{dataset}.{name}")
ref = {"projectId": project, "datasetId": dataset, "tableId": name}
grants = []
for listed in bq("ls", "--max_results=1000"):
    source = listed["datasetReference"]["datasetId"]
    for entry in bq("show", f"{project}:{source}").get("access", []):
        if entry.get("view") == ref:
            grants.append({"dataset": source, "entry": entry})
backup = {"query": view["view"]["query"], "description": view.get("description", ""), "grants": grants}
with open(path + ".tmp", "w") as out:
    json.dump(backup, out, indent=2)
print(f"{name}: saved the view and {len(grants)} authorised-view entries to {path}")
PY
    mv "$BACKUP/$1.json.tmp" "$BACKUP/$1.json"
}

swap() {
    local staging="$1" name="$2" current
    current="$(kind "$DATASET" "$name")"
    if [ "$current" = TABLE ]; then
        echo "$name: already a table, left alone"
        return
    fi
    if [ "$current" = VIEW ]; then
        [ -f "$BACKUP/$name.json" ] || save "$name"
        if [ "$(kind "$DATASET" "${name}__swap")" = none ]; then
            [ "$(kind "$staging" "$name")" = TABLE ] || {
                echo "$name: $staging.$name is not a table" >&2
                return 1
            }
            bqq cp --force=false "$PROJECT:$staging.$name" "$PROJECT:$DATASET.${name}__swap" >/dev/null
        fi
        if [ "$(columns "$DATASET" "$name")" != "$(columns "$DATASET" "${name}__swap")" ]; then
            echo "$name: ${name}__swap's columns differ from the view's; the view is untouched" >&2
            return 1
        fi
        bqq rm -f -t "$PROJECT:$DATASET.$name"
    elif [ "$(kind "$DATASET" "${name}__swap")" != TABLE ]; then
        echo "$name: neither $DATASET.$name nor ${name}__swap exists" >&2
        return 1
    fi
    bqq query --location=EU --use_legacy_sql=false \
        "ALTER TABLE \`$PROJECT.$DATASET.${name}__swap\` RENAME TO \`$name\`" >/dev/null
    echo "$name: swapped in the table"
}

restore() {
    local name="$1" file="$BACKUP/$1.json" tmp query description
    [ -f "$file" ] || {
        echo "$name: no backup at $file" >&2
        return 1
    }
    if [ "$(kind "$DATASET" "$name")" = TABLE ]; then
        bqq query --location=EU --use_legacy_sql=false \
            "ALTER TABLE \`$PROJECT.$DATASET.$name\` RENAME TO \`${name}__rolled_back\`" >/dev/null
        echo "$name: moved the table to ${name}__rolled_back"
    fi
    if [ "$(kind "$DATASET" "$name")" = none ]; then
        query="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["query"])' "$file")"
        description="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"])' "$file")"
        bqq mk --use_legacy_sql=false --view="$query" --description="$description" \
            "$PROJECT:$DATASET.$name" >/dev/null
        echo "$name: recreated the view"
    fi
    tmp="$(mktemp -d)"
    for d in $(python3 -c 'import json,sys; print(" ".join(sorted({g["dataset"] for g in json.load(open(sys.argv[1]))["grants"]})))' "$file"); do
        bqq show --format=json "$PROJECT:$d" >"$tmp/$d.json"
        if python3 - "$tmp/$d.json" "$file" "$d" <<'PY'; then
import json, sys
meta_path, backup_path, dataset = sys.argv[1:4]
meta = json.load(open(meta_path))
access = meta.setdefault("access", [])
missing = [g["entry"] for g in json.load(open(backup_path))["grants"]
           if g["dataset"] == dataset and g["entry"] not in access]
access.extend(missing)
json.dump({"access": access}, open(meta_path, "w"))
sys.exit(0 if missing else 1)
PY
            bqq update --source "$tmp/$d.json" "$PROJECT:$d" >/dev/null
            echo "$name: authorised the view on $d"
        fi
    done
    rm -rf "$tmp"
}

[ $# -ge 2 ] || usage
mode="$1"
shift
mkdir -p "$BACKUP"
done_count=0
case "$mode" in
swap)
    staging="$1"
    shift
    [ $# -ge 1 ] || usage
    for name in "$@"; do
        swap "$staging" "$name"
        done_count=$((done_count + 1))
    done
    ;;
restore)
    for name in "$@"; do
        restore "$name"
        done_count=$((done_count + 1))
    done
    ;;
*) usage ;;
esac
[ "$done_count" -gt 0 ] || {
    echo "no name handled" >&2
    exit 1
}
echo "$mode: $done_count names handled in $DATASET"
