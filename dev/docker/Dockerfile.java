ARG BASE_IMAGE=eclipse-temurin:21-jre-jammy
FROM ${BASE_IMAGE}
ARG PERSONALIZATION_USERNAME
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash "${PERSONALIZATION_USERNAME}"
USER ${PERSONALIZATION_USERNAME}
WORKDIR /work
ENTRYPOINT ["java"]
