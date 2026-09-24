ARG BASE_IMAGE=eclipse-temurin:21-jre-jammy
FROM ${BASE_IMAGE}
ARG PERSONALIZATION_USERNAME
ARG PERSONALIZATION_UID=1401
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fL "https://github.com/coursier/coursier/releases/latest/download/cs-x86_64-pc-linux.gz" | gzip -d > /usr/local/bin/cs && \
    chmod +x /usr/local/bin/cs && \
    useradd -m -u "${PERSONALIZATION_UID}" -s /bin/bash "${PERSONALIZATION_USERNAME}" && \
    mkdir -p "/home/${PERSONALIZATION_USERNAME}/.sbt" "/home/${PERSONALIZATION_USERNAME}/.ivy2" && \
    chown -R "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "/home/${PERSONALIZATION_USERNAME}"
USER ${PERSONALIZATION_USERNAME}
RUN cs install sbt
ENV PATH="/home/${PERSONALIZATION_USERNAME}/.local/share/coursier/bin:${PATH}"
WORKDIR /work
ENTRYPOINT ["sbt"]
