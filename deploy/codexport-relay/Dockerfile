FROM swift:6.2-jammy AS build

WORKDIR /workspace
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product codexport-relay --static-swift-stdlib

FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libatomic1 libcurl4 libxml2 tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --home /var/lib/codexport-relay --create-home --shell /usr/sbin/nologin codexport

COPY --from=build /workspace/.build/release/codexport-relay /usr/local/bin/codexport-relay
COPY deploy/codexport-relay/entrypoint.sh /usr/local/bin/codexport-relay-entrypoint

RUN chmod +x /usr/local/bin/codexport-relay /usr/local/bin/codexport-relay-entrypoint

USER codexport
WORKDIR /var/lib/codexport-relay
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/codexport-relay-entrypoint"]
