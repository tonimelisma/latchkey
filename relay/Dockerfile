# The Latchkey relay: one static binary on a distroless base, data in /data (plan D10, FR-080).
# The build stage runs natively and cross-compiles for the target (no emulation).
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/relay ./cmd/relay \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/relay /relay
COPY --from=build --chown=nonroot:nonroot /out/data /data
ENV DATA_DIR=/data PORT=8080
VOLUME /data
EXPOSE 8080
USER nonroot
HEALTHCHECK --interval=30s --timeout=5s CMD ["/relay", "healthcheck"]
ENTRYPOINT ["/relay"]
