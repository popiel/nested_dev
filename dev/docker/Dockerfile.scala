ARG BASE_IMAGE=coursier/jre:21
FROM ${BASE_IMAGE}
ARG PERSONALIZATION_USERNAME
RUN cs install scala:3.5.2 && \
    echo "export PATH=~/.local/share/coursier/bin:\$PATH" >> /home/cs/.bashrc
# Re-home coursier install to the actual user
RUN if [ "${PERSONALIZATION_USERNAME}" != "cs" ]; then \
        usermod -m -d "/home/${PERSONALIZATION_USERNAME}" cs && \
        mv "/home/cs/.local" "/home/${PERSONALIZATION_USERNAME}/.local" 2>/dev/null || true && \
        mv "/home/cs/.bashrc" "/home/${PERSONALIZATION_USERNAME}/.bashrc" 2>/dev/null || true && \
        usermod -l "${PERSONALIZATION_USERNAME}" cs && \
        echo "export PATH=~/.local/share/coursier/bin:\$PATH" >> "/home/${PERSONALIZATION_USERNAME}/.bashrc"; \
    fi
USER ${PERSONALIZATION_USERNAME}
WORKDIR /work
ENTRYPOINT ["scala"]
