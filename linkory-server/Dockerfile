FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/linkory-server ./cmd/linkory-server

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/linkory-server /linkory-server
EXPOSE 8080
ENTRYPOINT ["/linkory-server"]
