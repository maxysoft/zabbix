FROM golang:1.27.2-alpine@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 GOBIN=/out go install -trimpath -ldflags=-s filippo.io/age/cmd/age@$AGE_VERSION filippo.io/age/cmd/age-keygen@$AGE_VERSION

FROM timescale/timescaledb:2.29.2-pg18@sha256:9508616d5b941ed931198504c5db3fb47e8f53f790732ea1e889591f1062057c
COPY --from=age /out/ /usr/local/bin/
