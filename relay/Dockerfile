# The Latchkey relay: one static binary on a distroless base, data in /data (plan D10, FR-080).
# The build stage runs natively and cross-compiles for the target (no emulation).
# Base images are pinned by digest so a build is repeatable; Dependabot proposes updates.
FROM --platform=$BUILDPLATFORM golang:1.27.3@sha256:e519d3b0a5b285e5aa53ab9eef02bc6bbb9cb04608389b743a136a9ce75f0d1e AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/relay ./cmd/relay \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/relay /relay
COPY --from=build --chown=nonroot:nonroot /out/data /data
ENV DATA_DIR=/data PORT=8080
VOLUME /data
EXPOSE 8080
USER nonroot
HEALTHCHECK --interval=30s --timeout=5s CMD ["/relay", "healthcheck"]
ENTRYPOINT ["/relay"]
