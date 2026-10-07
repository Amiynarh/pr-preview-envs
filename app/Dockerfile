# -----------------------------------------------------------
# Stage 1: Build
# -----------------------------------------------------------
FROM golang:1.27-alpine AS builder

# These are injected by the CI pipeline at build time
ARG PR_NUMBER=local
ARG GIT_SHA=dev

WORKDIR /app

# Copy go.mod first so Docker can cache the dependency layer
COPY go.mod .
RUN go mod download

COPY main.go .

# -w -s strips debug symbols (~30% smaller binary)
# -X overwrites package-level string variables at link time
RUN CGO_ENABLED=0 go build \
    -ldflags="-w -s -X main.prNumber=${PR_NUMBER} -X main.gitSha=${GIT_SHA}" \
    -o server main.go

# -----------------------------------------------------------
# Stage 2: Runtime
# -----------------------------------------------------------
FROM alpine:latest

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

WORKDIR /app
COPY --from=builder /app/server .

EXPOSE 8080
CMD ["./server"]

