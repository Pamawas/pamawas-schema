# Use the official Golang image to build the application
FROM golang:1.27-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -o pamawas-schema .

FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /app/pamawas-schema .
COPY --from=builder /app/migrations ./migrations

EXPOSE 8080

CMD ["./pamawas-schema"]