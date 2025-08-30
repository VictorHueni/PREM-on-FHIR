# PREM-on-FHIR
```
docker compose --profile all up -d
```

## Questionnaire
```
python questionnaire_bundle_maker.py --in ./input --out ./output/questionnaire_bundle.json
./upload_questionnaire.sh
```

## Synthea
```
docker build -t syntheadocker .
docker run --rm -it --mount type=bind,source="$(pwd)/output",target=/output syntheadocker
./upload_patient.sh
```

## Create Questionnaire Header
```
python -m venv .venv
.venv/Scripts/activate
pip install --upgrade pip
pip install psycopg2-binary python-dotenv
python export_qr_header.py
```


## QR Bundle maker

```
python -m venv .venv
.venv/Scripts/activate
python -m pip install -r requirements.txt
python qr_bundle_maker.py --mode ppnq --csv ./input/QuestionnaireResponse-Header.csv --out output --llm
python qr_bundle_maker.py --mode ppnq --csv ./input/QuestionnaireResponse-Header.csv --out output --dry-run
python qr_bundle_maker.py --mode nreq --csv ./input/QuestionnaireResponse-Header.csv --out output --seed 42 --likert-dist 0.2,0.5,0.3
./upload_patient.sh
```



### ELT


## Airbytes (extract load)
abctl local credentials
abctl local status


## Transform (transform)

`dbt clean && dbt deps`
`dbt compile --select stg.*`
`dbt build --select stg.*`

Models only: `dbt run`

Just tests: `dbt test`

Full refresh (rebuild tables): `dbt build --full-refresh`

Run a folder (e.g., core only): `dbt run -s models/core/` (or) `dbt run -s core`

Include parents/children: `dbt build -s +core` (with upstream) or `dbt build -s core+` (with downstream)

Faster local runs: `dbt build --threads 6`

Only changed models (iterating):
run once normally to create a state manifest
`dbt build --select state:modified+ --state target/`