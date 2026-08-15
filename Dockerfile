# Use the official Golang image to build the application
FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -o migration-runner .

FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /app/migration-runner .
COPY --from=builder /app/migrations ./migrations

EXPOSE 8080

CMD ["./migration-runner"]