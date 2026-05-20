# ---------- Build stage ----------
FROM alpine:3.20 AS builder

RUN apk add --no-cache \
    build-base \
    curl-dev \
    libxml2-dev \
    openssl-dev \
    git \
    pkgconf

WORKDIR /app
COPY . /app

RUN git clone https://git.bwaaa.monster/beaker /tmp/beaker && \
    cd /tmp/beaker && \
    make && make install && \
    rm -rf /tmp/beaker

RUN make clean && make && strip bin/omnisearch

# ---------- Runtime stage ----------
FROM alpine:3.20

RUN apk add --no-cache \
    libcurl \
    libxml2 \
    openssl

WORKDIR /app

# Copy only required artifacts
COPY --from=builder /app/bin/omnisearch /app/omnisearch
COPY --from=builder /usr/lib/libbeaker.so /usr/lib/libbeaker.so
COPY --from=builder /app/templates /app/templates
COPY --from=builder /app/static /app/static

# Security: non-root user
RUN adduser -D appuser && chmod +x /app/omnisearch
USER appuser

ENV LD_LIBRARY_PATH=/usr/lib

EXPOSE 5000

CMD ["/app/omnisearch"]
