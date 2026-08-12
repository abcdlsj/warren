FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY relayassets.go ./
COPY Packages/WebRelay/Sources/WebRelay/Resources ./Packages/WebRelay/Sources/WebRelay/Resources
COPY RelayService ./RelayService
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/burrow-relay ./RelayService/cmd/burrow-relay

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/burrow-relay /burrow-relay
VOLUME ["/data"]
ENV BURROW_RELAY_LISTEN=:8080
ENV BURROW_RELAY_DATA=/data/registry.json
EXPOSE 8080
ENTRYPOINT ["/burrow-relay"]
