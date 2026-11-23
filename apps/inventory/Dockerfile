# Stage 1: build a static Go binary
FROM golang:1.27.4-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
# CGO off = fully static binary that runs on "scratch".
# Symbols are kept (no -ldflags="-s -w"): OBI finds Go functions for its uprobes
# using the symbol table, so stripping can reduce what OBI sees.
RUN CGO_ENABLED=0 go build -o /inventory .

# Stage 2: empty image + our binary only, non-root
FROM scratch
COPY --from=build /inventory /inventory
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/inventory"]
