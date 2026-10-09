FROM golang:1.26.5-bookworm AS build
ARG GOPROXY=https://proxy.golang.org,direct
ARG VERSION=dev
ENV GOPROXY=${GOPROXY}
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X github.com/linkory/linkory-server/internal/httpapi.Version=${VERSION}" -o /out/linkory-server ./cmd/linkory-server

FROM alpine:3.22
RUN adduser -D -u 10001 linkory
USER linkory
COPY --from=build /out/linkory-server /usr/local/bin/linkory-server
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["linkory-server"]
