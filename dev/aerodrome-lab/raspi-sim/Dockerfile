FROM geerlingguy/docker-ubuntu2404-ansible:latest

ARG DEPLOY_USER=deploy

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        iputils-ping \
        iproute2 \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash "${DEPLOY_USER}" \
    && echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${DEPLOY_USER} \
    && chmod 0440 /etc/sudoers.d/${DEPLOY_USER} \
    && mkdir -p /home/${DEPLOY_USER}/.ssh \
    && chmod 700 /home/${DEPLOY_USER}/.ssh \
    && chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh

COPY --chown=${DEPLOY_USER}:${DEPLOY_USER} ssh/authorized_keys /home/${DEPLOY_USER}/.ssh/authorized_keys
RUN chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys

RUN mkdir -p /var/run/sshd \
    && systemctl enable ssh

EXPOSE 22

CMD ["/lib/systemd/systemd"]
