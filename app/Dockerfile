# syntax=docker/dockerfile:1

# Build stage: full Go toolchain, thrown away after the build.
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY *.go ./
# Static binary (no libc), no debug symbols, reproducible paths.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/trdl .

# Runtime stage: distroless static has no shell and no package manager.
# The nonroot tag runs as UID 65532.
FROM gcr.io/distroless/static-debian12:nonroot
ARG REVISION=unknown
LABEL org.opencontainers.image.title="trdl" \
      org.opencontainers.image.revision="${REVISION}"
COPY --from=build /out/trdl /trdl
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/trdl"]
