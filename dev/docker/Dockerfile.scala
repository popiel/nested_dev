ARG BASE_IMAGE=eclipse-temurin:21-jre-jammy
FROM ${BASE_IMAGE}
ARG PERSONALIZATION_USERNAME
ARG PERSONALIZATION_UID=1401
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fL "https://github.com/coursier/coursier/releases/latest/download/cs-x86_64-pc-linux.gz" | gzip -d > /usr/local/bin/cs && \
    chmod +x /usr/local/bin/cs && \
    useradd -m -u "${PERSONALIZATION_UID}" -s /bin/bash "${PERSONALIZATION_USERNAME}"
USER ${PERSONALIZATION_USERNAME}
RUN cs install scala:3.5.2
ENV PATH="/home/${PERSONALIZATION_USERNAME}/.local/share/coursier/bin:${PATH}"
WORKDIR /work
ENTRYPOINT ["scala"]
