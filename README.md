# PREM-on-FHIR
```
docker compose up -d
```

## Synthea
```
docker build -t syntheadocker .
docker run --rm -it --mount type=bind,source="$(pwd)/output",target=/output syntheadocker
```