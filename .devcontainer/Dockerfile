FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset.
# shellcheck: available here for interactive/manual linting of the .sh files
# in this repo (.devcontainer/*.sh, scripts/*.sh, tools/run-overnight.sh,
# etc.) inside the sandbox; CI also runs it non-interactively as its own
# preinstalled-on-the-runner job (see .github/workflows/tests.yml) so this
# copy isn't the only gate.
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  curl \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  shellcheck \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}


# Install bd (beads issue tracker) directly from a pinned GitHub release.
# Done at BUILD time (network is open here) so the locked-down runtime firewall
# never needs to reach GitHub releases for it.
#
# NOTE: upstream's scripts/install.sh (gastownhall/beads) always resolves
# "latest" via the GitHub API and has no version-pin env var — piping it from
# the mutable `main` branch into `bash` would give anyone who lands a commit
# there code execution in every future image build, with no review gate and
# no diff on rebuild. So we bypass that script entirely: fetch the exact
# release archive for a pinned tag, verify its SHA256 against a value vendored
# in this Dockerfile (copied from that release's published checksums.txt), and
# only then extract it — no downloaded script is ever executed.
#
# To bump: pick a new tag from https://github.com/gastownhall/beads/releases,
# update BEADS_VERSION, and replace the two SHA256s below from that release's
# checksums.txt (linux_amd64 / linux_arm64 rows). Still not defense-in-depth
# against a compromised GitHub account publishing a bad release+checksums
# pair — vendoring a checksum only pins to *a* release, not to code review.
ARG BEADS_VERSION=v1.0.4
ARG BEADS_SHA256_LINUX_AMD64=643e602e27f666c8726abff0f22001e2b5883988fa960204bde20a3129d448a5
ARG BEADS_SHA256_LINUX_ARM64=48cdf571cd8b64bae81da829c1309e402bc12e6a4cc6b87606dfc9220b7ece60
ENV BEADS_INSTALL_DIR=/usr/local/share/npm-global/bin
RUN set -eux; \
  dpkg_arch="$(dpkg --print-architecture)"; \
  case "$dpkg_arch" in \
    amd64) beads_sha256="$BEADS_SHA256_LINUX_AMD64" ;; \
    arm64) beads_sha256="$BEADS_SHA256_LINUX_ARM64" ;; \
    *) echo "Unsupported architecture for beads: $dpkg_arch" >&2; exit 1 ;; \
  esac; \
  beads_archive="beads_${BEADS_VERSION#v}_linux_${dpkg_arch}.tar.gz"; \
  beads_url="https://github.com/gastownhall/beads/releases/download/${BEADS_VERSION}/${beads_archive}"; \
  curl -fsSL "$beads_url" -o "/tmp/${beads_archive}"; \
  printf '%s  /tmp/%s\n' "$beads_sha256" "$beads_archive" > /tmp/beads.sha256; \
  sha256sum -c /tmp/beads.sha256; \
  mkdir -p /tmp/beads-extract; \
  tar -xzf "/tmp/${beads_archive}" -C /tmp/beads-extract; \
  beads_bin="$(find /tmp/beads-extract -maxdepth 2 -type f -name bd -print -quit)"; \
  [ -n "$beads_bin" ]; \
  install -m 0755 "$beads_bin" "$BEADS_INSTALL_DIR/bd"; \
  ln -sf bd "$BEADS_INSTALL_DIR/beads"; \
  rm -rf /tmp/beads-extract "/tmp/${beads_archive}" /tmp/beads.sha256; \
  bd version


# Copy and set up firewall script (firewall-common.sh is the shared skeleton
# also used by Dockerfile.ollama/ollama-init-firewall.sh -- init-firewall.sh
# sources it at runtime, so it must be present alongside it in the image).
COPY firewall-common.sh /usr/local/bin/firewall-common.sh
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/firewall-common.sh /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node