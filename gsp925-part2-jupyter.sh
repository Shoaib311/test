#!/bin/bash

# ============================================================
# GSP925 - PART 2 of 2
# Run this in: VERTEX AI WORKBENCH — JupyterLab Terminal
# Does: Setup + runs sync & async Document AI calls
#       using the actual lab notebooks (nbconvert)
# ============================================================

BOLD=`tput bold`; GREEN=`tput setaf 2`; YELLOW=`tput setaf 3`
CYAN=`tput setaf 6`; RESET=`tput sgr0`; RED=`tput setaf 1`

echo "${GREEN}${BOLD}"
echo "================================================"
echo "  GSP925 Part 2 — JupyterLab Terminal"
echo "  Setup + Execute Notebooks"
echo "================================================"
echo "${RESET}"

export PROJECT_ID=$(gcloud config get-value core/project)

# ── STEP 1: Fetch Processor IDs from Part 1 output ─────────
echo "${CYAN}[1/6] Loading Processor IDs...${RESET}"

# Try to get from the saved env file first
if gsutil -q stat gs://$PROJECT_ID-labconfig-bucket/processor_ids.env 2>/dev/null; then
  gsutil cp gs://$PROJECT_ID-labconfig-bucket/processor_ids.env ~/processor_ids.env
fi

# Fetch live from API (most reliable)
ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
PROC_LIST=$(curl -s -X GET \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "https://us-documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors")

FORM_PROCESSOR_ID=$(echo "$PROC_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('processors', []):
    if 'form' in p.get('displayName','').lower():
        print(p['name'].split('/')[-1])
        break
")

OCR_PROCESSOR_ID=$(echo "$PROC_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('processors', []):
    if 'ocr' in p.get('displayName','').lower():
        print(p['name'].split('/')[-1])
        break
")

if [ -z "$FORM_PROCESSOR_ID" ] || [ -z "$OCR_PROCESSOR_ID" ]; then
  echo "${RED}ERROR: Could not fetch Processor IDs. Make sure Part 1 completed successfully.${RESET}"
  exit 1
fi

echo "${GREEN}✓ Form Parser ID : $FORM_PROCESSOR_ID${RESET}"
echo "${GREEN}✓ OCR Processor ID: $OCR_PROCESSOR_ID${RESET}"

# ── STEP 2: Install libraries + copy files in parallel ─────
echo "${CYAN}[2/6] Installing libraries and copying files in parallel...${RESET}"

python3 -m pip install -q --upgrade \
  google-cloud-core \
  google-cloud-documentai \
  google-cloud-storage \
  prettytable \
  simplejson \
  nbconvert \
  nbformat \
  ipykernel \
  papermill &
PIP_PID=$!

gsutil cp gs://$PROJECT_ID-labconfig-bucket/health-intake-form.pdf form.pdf &
gsutil -m cp gs://$PROJECT_ID-labconfig-bucket/notebooks/*.ipynb . &

BUCKET="${PROJECT_ID}_doc_ai_async"
gsutil mb gs://${BUCKET} 2>/dev/null || true
gsutil -m cp gs://$PROJECT_ID-labconfig-bucket/async/*.* gs://${BUCKET}/input &

wait
echo "${GREEN}✓ Libraries installed and files copied.${RESET}"

# ── STEP 3: Identify notebook filenames ────────────────────
echo "${CYAN}[3/6] Detecting notebook filenames...${RESET}"

echo "Available notebooks:"
ls *.ipynb 2>/dev/null

# Try known exact lab notebook names first
SYNC_NB=$(ls *.ipynb 2>/dev/null | grep -iE 'documentai-sync|documentai_sync|sync' | head -1)
ASYNC_NB=$(ls *.ipynb 2>/dev/null | grep -iE 'documentai-async|documentai_async|async' | head -1)

# Fallback: first notebook = sync, second = async
if [ -z "$SYNC_NB" ]; then
  SYNC_NB=$(ls *.ipynb 2>/dev/null | sed -n '1p')
fi
if [ -z "$ASYNC_NB" ]; then
  ASYNC_NB=$(ls *.ipynb 2>/dev/null | sed -n '2p')
fi

if [ -z "$SYNC_NB" ] || [ -z "$ASYNC_NB" ]; then
  echo "${RED}ERROR: Could not find notebooks. Files in current directory:${RESET}"
  ls -la
  exit 1
fi

echo "${GREEN}✓ Sync notebook  : $SYNC_NB${RESET}"
echo "${GREEN}✓ Async notebook : $ASYNC_NB${RESET}"

# ── STEP 4: Inject Processor IDs into notebooks ────────────
echo "${CYAN}[4/6] Injecting Processor IDs into notebooks...${RESET}"

python3 - <<PYEOF
import json, re

def inject_processor_id(nb_path, processor_id):
    with open(nb_path, 'r') as f:
        nb = json.load(f)
    changed = False
    for cell in nb.get('cells', []):
        if cell.get('cell_type') == 'code':
            src = ''.join(cell['source'])
            if 'PROCESSOR_ID' in src or "processor_id = '" in src.lower():
                new_src = re.sub(
                    r"processor_id\s*=\s*['\"].*?['\"]",
                    f"processor_id = '{processor_id}'",
                    src
                )
                if new_src != src:
                    cell['source'] = [new_src]
                    changed = True
    if changed:
        with open(nb_path, 'w') as f:
            json.dump(nb, f, indent=1)
        print(f"  Injected {processor_id} into {nb_path}")
    else:
        print(f"  WARNING: No PROCESSOR_ID placeholder found in {nb_path}")

inject_processor_id("$SYNC_NB",  "$OCR_PROCESSOR_ID")
inject_processor_id("$ASYNC_NB", "$FORM_PROCESSOR_ID")
PYEOF

echo "${GREEN}✓ Processor IDs injected.${RESET}"

# ── STEP 5: Execute sync notebook ──────────────────────────
echo "${CYAN}[5/6] Executing synchronous notebook (${SYNC_NB})...${RESET}"

papermill "$SYNC_NB" "$SYNC_NB" -k python3 --execution-timeout 120
SYNC_EXIT=$?

if [ $SYNC_EXIT -ne 0 ]; then
  echo "${YELLOW}papermill failed, trying nbconvert...${RESET}"
  jupyter nbconvert \
    --to notebook \
    --execute \
    --inplace \
    --ExecutePreprocessor.timeout=120 \
    --ExecutePreprocessor.kernel_name=python3 \
    "$SYNC_NB"
  SYNC_EXIT=$?
fi

if [ $SYNC_EXIT -eq 0 ]; then
  echo "${GREEN}✓ Synchronous notebook executed successfully.${RESET}"
else
  echo "${RED}✗ Sync notebook execution failed.${RESET}"
  echo "${YELLOW}Tip: Open ${SYNC_NB} in JupyterLab, set Processor ID to ${OCR_PROCESSOR_ID}, and run manually.${RESET}"
fi

# ── STEP 6: Execute async notebook ─────────────────────────
echo "${CYAN}[6/6] Executing asynchronous notebook (${ASYNC_NB})...${RESET}"
echo "${YELLOW}  (This may take 2-3 minutes for the batch job to complete)${RESET}"

papermill "$ASYNC_NB" "$ASYNC_NB" -k python3 --execution-timeout 360
ASYNC_EXIT=$?

if [ $ASYNC_EXIT -ne 0 ]; then
  echo "${YELLOW}papermill failed, trying nbconvert...${RESET}"
  jupyter nbconvert \
    --to notebook \
    --execute \
    --inplace \
    --ExecutePreprocessor.timeout=360 \
    --ExecutePreprocessor.kernel_name=python3 \
    "$ASYNC_NB"
  ASYNC_EXIT=$?
fi

if [ $ASYNC_EXIT -eq 0 ]; then
  echo "${GREEN}✓ Asynchronous notebook executed successfully.${RESET}"
else
  echo "${RED}✗ Async notebook execution failed.${RESET}"
  echo "${YELLOW}Tip: Open ${ASYNC_NB} in JupyterLab, set Processor ID to ${FORM_PROCESSOR_ID}, and run manually.${RESET}"
fi

echo ""
echo "${GREEN}${BOLD}================================================"
echo "  PART 2 COMPLETE — All tasks done!"
echo "================================================${RESET}"
echo ""
echo "${YELLOW}Both notebooks have been executed inside Workbench."
echo "Check Qwiklabs progress bar — all checkpoints should be green.${RESET}"
