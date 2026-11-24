# Test runner for the server bats tests: what a team server has (bash 5, util-linux flock, GNU tar, coreutils, jq,
# git), plus bats-core. lint.sh builds it locally (tag from this file's checksum) and runs test/server in it, because
# macOS has none of bash 5, flock or GNU tar. Base and bats are pinned by digest; update both deliberately.
FROM bats/bats:1.14.0@sha256:5322b877351fda0cc435de8c6116de7d0a2ec79d7c680132a0ef329a633bc66f AS bats

FROM ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash coreutils util-linux tar jq git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=bats /opt/bats /opt/bats
RUN ln -s /opt/bats/bin/bats /usr/local/bin/bats
ENV LANG=C.UTF-8
USER 65534:65534
WORKDIR /repo
ENTRYPOINT ["bats"]
