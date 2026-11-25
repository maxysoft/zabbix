FROM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 GOBIN=/out go install -trimpath -ldflags=-s filippo.io/age/cmd/age@$AGE_VERSION filippo.io/age/cmd/age-keygen@$AGE_VERSION

FROM timescale/timescaledb:2.29.3-pg18@sha256:7e64c171a6b6ff42d39252658e893485080b53226c173c8fc0b7caa8518c4023
RUN apk upgrade --no-cache
COPY --from=age /out/ /usr/local/bin/
