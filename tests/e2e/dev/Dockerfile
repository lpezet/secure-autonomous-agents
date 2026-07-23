# The client side of the e2e stack: a dev container with the tools the tests
# drive (git, gh, curl, jq) and nothing else.
#
# FROM the image run.sh builds out of stack/dev, so this stays the real base
# image rather than a copy of it that can drift. run.sh must build that tag
# before `compose build` — see _build_devbase there.
ARG DEVBASE=sat-e2e-devbase
FROM ${DEVBASE}

# gh is not in the base image; the dev-container example adds it the same way.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
