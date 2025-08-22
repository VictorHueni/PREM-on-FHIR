# PREM-on-FHIR
```
docker compose up -d
```

## Synthea
```
docker build -t syntheadocker .
docker run --rm -it --mount type=bind,source="$(pwd)/output",target=/output syntheadocker
```

## QR Bundle maker
```
python qr_bundle_maker.py --mode ppnq --csv QuestionnaireResponse-Header.csv --out output --llm
python qr_bundle_maker.py --mode ppnq --csv QuestionnaireResponse-Header.csv --out output --dry-run
python qr_bundle_maker.py --mode nreq --csv QuestionnaireResponse-Header.csv --out output --seed 42 --likert-dist 0.2,0.5,0.3
```


