FROM eclipse-temurin:17-jdk

WORKDIR /app
RUN curl -L -O https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar

COPY keeps/ /app/keeps/

# sensible defaults 
ENV KEEP_FILE=keep_neuro.json \
    POPULATION=5 \
    AGE_RANGE=18-100 \
    EXTRA_ARGS="--exporter.fhir.export=true --exporter.baseDirectory=/output --generate.only_alive_patients=true --generate.max_attempts_to_keep_patient=20000"

RUN printf '#!/usr/bin/env bash\nset -e\nexec java -jar /app/synthea-with-dependencies.jar -p "${POPULATION}" -a "${AGE_RANGE}" -k "/app/keeps/${KEEP_FILE}" ${EXTRA_ARGS} "$@"\n' > /app/run.sh \
    && chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
