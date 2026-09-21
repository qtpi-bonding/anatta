FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends emacs-nox git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# anatta-git-commit needs a git identity to actually commit (git add
# succeeds with none; git commit silently no-ops per anatta-git-commit's
# own unchecked-failure design, defeating the git-recoverability the
# whole self-modification story depends on) — found via live
# verification against the real mounted repo, not caught by ERT (every
# test uses a throwaway git-initialized temp dir with its own identity).
RUN git config --global user.email "anatta@localhost" && \
    git config --global user.name "anatta" && \
    git config --global --add safe.directory /repo

WORKDIR /agent
COPY entrypoint.sh /agent/entrypoint.sh
RUN chmod +x /agent/entrypoint.sh

ENTRYPOINT ["/agent/entrypoint.sh"]
