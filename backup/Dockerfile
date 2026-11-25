FROM golang:1.27.4-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 GOBIN=/out go install -trimpath -ldflags=-s filippo.io/age/cmd/age@$AGE_VERSION filippo.io/age/cmd/age-keygen@$AGE_VERSION

FROM timescale/timescaledb:2.29.3-pg18@sha256:7e64c171a6b6ff42d39252658e893485080b53226c173c8fc0b7caa8518c4023
RUN apk upgrade --no-cache
COPY --from=age /out/ /usr/local/bin/
