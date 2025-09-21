# ------- basics -------
SHELL := bash

# Prefer venv python if present (Windows or POSIX), else fall back to system python
PY := python
ifneq ("$(wildcard .venv/Scripts/python.exe)","")
  PY := .venv/Scripts/python.exe
endif
ifneq ("$(wildcard .venv/bin/python)","")
  PY := .venv/bin/python
endif

# Run the refactored CLI package (lives in 99-tools/pof_cli/)
# Important: put 99-tools on PYTHONPATH so `-m pof_cli` imports.
POF := PYTHONPATH=99-tools $(PY) -m pof_cli

# ------- config you may tweak -------
# FHIR server base (override from .env automatically; this is just a fallback)
FHIR_BASE ?= http://localhost:8080/fhir

# Synthea locations
SYN_CONTEXT := 01-data-generation/synthea
SYN_OUT     := $(SYN_CONTEXT)/output

# Bulk $import
IMPORT_PARAMS ?= $(SYN_CONTEXT)/import-pass1.json   # point this at your Parameters JSON
IMPORT_FILES ?= $(SYN_CONTEXT)/import-pass1.json \
                $(SYN_CONTEXT)/import-pass2.json
IMPORT_POLL   ?= 30                           	# seconds between polls
IMPORT_TIMEOUT_MIN ?= 60                      	# total minutes before giving up

# Questionnaire source (folder with CodeSystem/ValueSet/Questionnaire JSON files)
Q_CONTEXT   := 01-data-generation/questionnaires
Q_IN_DIR    := $(Q_CONTEXT)/input
Q_BUNDLE    := $(Q_CONTEXT)/output/_questionnaires.transaction.bundle.json

# Header CSV and QR bundles
QR_CONTEXT  := 01-data-generation/questionnaire_responses
HDR_OUT     := $(QR_CONTEXT)/input
HDR_CSV     := $(HDR_OUT)/QuestionnaireResponse-Header.csv
QR_OUT      := $(QR_CONTEXT)/output
QR_MODE     ?= nreq             # or ppnq
QR_CHUNK    := 250
QR_SEED     := 42

# For NREQ weighting (optional): e.g. QR_LIKERT_DIST=0.2,0.5,0.3
QR_LIKERT_DIST ?=

# PPNQ generation toggles
QR_DRY_RUN     ?= 1             # 1=on, 0=off
QR_USE_LLM     ?= 0             # 1=on, 0=off
LLM_MODEL      ?= gpt-4o-mini
LLM_TEMPERATURE?= 0.6
LLM_MAX_RETRIES?= 3
QR_VERBOSE     ?= 0

# Docker image tag
SYN_TAG     := syntheadocker

# ------- phony targets -------
.PHONY: init venv deps fhir-wait synthea-build synthea-run\
        bundle-questionnaires post-questionnaires\
        qr-export-headers qr-make-bundles post-qr-bundles\
        seed-all clean

# ------- setup -------
init: venv deps

venv:
	@echo "🐍 Creating venv (if missing)…"
	@if [ ! -x ".venv/bin/python" ] && [ ! -x ".venv/Scripts/python.exe" ]; then \
		if command -v python3 >/dev/null 2>&1; then \
			python3 -m venv .venv || { echo "❌ Could not create venv. On Debian/Ubuntu/Kali run: sudo apt install python3-venv"; exit 1; }; \
		else \
			python -m venv .venv || { echo "❌ Could not create venv."; exit 1; }; \
		fi \
	fi
	@(. .venv/bin/activate 2>/dev/null || true) >/dev/null 2>&1 || true
	@echo "✅ venv ready"

deps: venv
	@echo "📦 Installing CLI deps…"
	@if [ -x ".venv/bin/python" ]; then \
		.venv/bin/python -m pip install -U pip setuptools wheel && \
		.venv/bin/python -m pip install -r 99-tools/requirements.txt ; \
	elif [ -x ".venv/Scripts/python.exe" ]; then \
		.venv/Scripts/python.exe -m pip install -U pip setuptools wheel && \
		.venv/Scripts/python.exe -m pip install -r 99-tools/requirements.txt ; \
	else \
		echo "❌ venv python not found"; exit 1; \
	fi

# ------- FHIR -------
fhir-wait:
	@echo "⏳ Waiting for HAPI at $(FHIR_BASE)…"
	@$(POF) fhir wait-ready --base "$(FHIR_BASE)" --interval 3 --timeout 120

# Bulk $import (Parameters JSON -> HAPI)
fhir-import:
	@echo "📥 Submitting bulk $import using $(IMPORT_PARAMS) → $(FHIR_BASE)…"
	@test -f "$(IMPORT_PARAMS)" || { echo "❌ Missing Parameters JSON: $(IMPORT_PARAMS)"; exit 1; }
	@$(POF) fhir import "$(IMPORT_PARAMS)" \
	  --base "$(FHIR_BASE)" \
	  --interval $(IMPORT_POLL) \
	  --timeout-minutes $(IMPORT_TIMEOUT_MIN)

# Bulk $import (many files, in order)
fhir-import-many:
	@echo "📥 Submitting bulk \$import for multiple files → $(FHIR_BASE)…"
	@set -e; \
	for f in $(IMPORT_FILES); do \
	  echo "—> 📦 $$f"; \
	  test -f "$$f" || { echo "❌ Missing Parameters JSON: $$f"; exit 1; }; \
	  $(POF) fhir import "$$f" \
	    --base "$(FHIR_BASE)" \
	    --interval $(IMPORT_POLL) \
	    --timeout-minutes $(IMPORT_TIMEOUT_MIN); \
	done
	@echo "✅ All imports completed."


# ------- Synthea -------
synthea-build:
	@echo "🔨 Building Synthea image '$(SYN_TAG)' from $(SYN_CONTEXT)…"
	@docker build -t $(SYN_TAG) $(SYN_CONTEXT)

# You can override population etc via environment or .env (POPULATION, AGE_RANGE, KEEP_FILE, EXTRA_ARGS)
synthea-run:
	@echo "🏃 Running Synthea into $(SYN_OUT)…"
	@$(POF) synthea run \
	  --image $(SYN_TAG) \
	  --output "$(SYN_OUT)" \
	  --population "$${POPULATION:-5}" \
	  --age-range "$${AGE_RANGE:-18-100}" \
	  --keep-file "$${KEEP_FILE:-keep_neuro.json}" \
	  --extra-args "$${EXTRA_ARGS:---exporter.fhir.bulk_data=true --exporter.baseDirectory=/output --generate.only_alive_patients=true --generate.max_attempts_to_keep_patient=20000}"

# ------- Questionnaire Bundle (CS/VS/Q -> transaction) -------
bundle-questionnaires:
	@echo "📦 Building Questionnaire transaction Bundle from $(Q_IN_DIR)…"
	@mkdir -p "$(Q_IN_DIR)"
	@$(POF) bundle make-questionnaires \
	  --indir "$(Q_IN_DIR)" \
	  --outfile "$(Q_BUNDLE)" \
	  --method auto

post-questionnaires:
	@echo "📮 Posting Questionnaire transaction Bundle → $(FHIR_BASE)…"
	@$(POF) fhir post-bundle "$(Q_BUNDLE)" --base "$(FHIR_BASE)" --timeout 120

# ------- Headers CSV from HAPI DB (SQL -> CSV) -------
qr-export-headers:
	@echo "🗂  Exporting header CSV from DB to $(HDR_CSV)…"
	@mkdir -p "$(HDR_OUT)"
	@$(POF) qr export-headers --outdir "$(HDR_OUT)"

# ------- Generate QR Bundles from header CSV -------
qr-make-bundles:
	@echo "🧰 Making QR bundles ($(strip $(QR_MODE))) → $(QR_OUT)…"
	@mkdir -p "$(QR_OUT)"
	@EXTRA=""; \
	if [ "$(strip $(QR_MODE))" = "nreq" ] && [ -n "$(QR_LIKERT_DIST)" ]; then \
	  EXTRA="$$EXTRA --likert-dist $(QR_LIKERT_DIST)"; \
	fi; \
	if [ "$(strip $(QR_MODE))" = "ppnq" ] && [ "$(QR_USE_LLM)" = "1" ]; then \
	  EXTRA="$$EXTRA --llm --llm-model $(LLM_MODEL) --llm-temperature $(LLM_TEMPERATURE) --llm-max-retries $(LLM_MAX_RETRIES)"; \
	fi; \
	if [ "$(strip $(QR_MODE))" = "ppnq" ] && [ "$(QR_DRY_RUN)" = "1" ]; then \
	  EXTRA="$$EXTRA --dry-run"; \
	fi; \
	if [ "$(strip $(QR_VERBOSE))" = "1" ]; then \
	  EXTRA="$$EXTRA --verbose"; \
	fi; \
	$(POF) qr make-bundles \
	  --mode $(strip $(QR_MODE)) \
	  --csv  "$(HDR_CSV)" \
	  --out  "$(QR_OUT)" \
	  --chunk-size $(QR_CHUNK) \
	  --seed $(QR_SEED) $$EXTRA

post-qr-bundles:
	@echo "📮 Posting QR bundles → $(FHIR_BASE)…"
	$(POF) fhir post-bundles \
	  --pattern "$(QR_OUT)/*_bundle_*.json" \
	  --base "$(FHIR_BASE)" \
	  --timeout 600 \
	  --accept --prefer-minimal \
	  --log-dir ./curl-logs

# ------- One button -------
seed-all: init synthea-build synthea-run fhir-wait  fhir-import-many \
          bundle-questionnaires post-questionnaires \
          qr-export-headers qr-make-bundles post-qr-bundles
	@echo "✅ seed-all complete."

# ------- utilities -------
clean:
	@echo "🧹 Cleaning generated files…"
	@rm -rf "$(SYN_OUT)" "$(QR_OUT)" "$(HDR_OUT)" ./curl-logs

# ------- dbt tasks -------
dbt-docs:           ## Generate dbt docs site
	docker compose run --rm dbt-run dbt docs generate

dbt-docs-serve:     ## Serve dbt docs site locally
	docker compose run --service-ports --rm dbt-run dbt docs serve --host 0.0.0.0 --port 8081 --no-browser

dbt-freshness:      ## Run source freshness and include it in docs
	docker compose run --rm dbt-run sh -lc '\
	  dbt source freshness --output json --target-path target && \
	  dbt docs generate \
	'