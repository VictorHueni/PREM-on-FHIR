# PREM-on-FHIR
```
docker compose up -d
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
python -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install psycopg2-binary python-dotenv
python export_qr_header.py
```


## QR Bundle maker


```
python qr_bundle_maker.py --mode ppnq --csv QuestionnaireResponse-Header.csv --out output --llm
python qr_bundle_maker.py --mode ppnq --csv QuestionnaireResponse-Header.csv --out output --dry-run
python qr_bundle_maker.py --mode nreq --csv QuestionnaireResponse-Header.csv --out output --seed 42 --likert-dist 0.2,0.5,0.3
./upload_patient.sh
```


