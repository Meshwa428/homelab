#!/bin/bash
# =============================================================================
# gen-certs.sh — Generate a local CA and wildcard cert for *.homeserver.com
# Run this once from the homelab root:
#   ./scripts/gen-certs.sh
#
# Then trust the CA file on each device:
#   core/reverse-proxy/certs/homeserver-ca.crt
# =============================================================================

set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/traefik/certs"
DOMAIN="homeserver.com"
CA_KEY="$CERT_DIR/ca.key"
CA_CERT="$CERT_DIR/ca.crt"
WILDCARD_KEY="$CERT_DIR/wildcard.key"
WILDCARD_CERT="$CERT_DIR/wildcard.crt"
DAYS_CA=3650      # CA valid for 10 years
DAYS_CERT=825     # Cert valid for ~2 years (browser max)

GREEN=$'\033[0;32m'
BOLD=$'\033[1m'
NC=$'\033[0m'

echo ""
echo -e "${BOLD}Generating local CA and wildcard cert for *.${DOMAIN}${NC}"
echo ""

mkdir -p "$CERT_DIR"

# --- 1. Generate CA key and self-signed CA cert ------------------------------
echo "  → Generating CA key..."
openssl genrsa -out "$CA_KEY" 4096 2>/dev/null

echo "  → Generating CA certificate (valid ${DAYS_CA} days)..."
openssl req -new -x509 \
  -key "$CA_KEY" \
  -out "$CA_CERT" \
  -days "$DAYS_CA" \
  -subj "/CN=Homeserver Local CA/O=Homelab/C=US" \
  2>/dev/null

# --- 2. Generate wildcard key and CSR ----------------------------------------
echo "  → Generating wildcard key..."
openssl genrsa -out "$WILDCARD_KEY" 2048 2>/dev/null

echo "  → Generating certificate signing request..."
openssl req -new \
  -key "$WILDCARD_KEY" \
  -out "$CERT_DIR/wildcard.csr" \
  -subj "/CN=*.${DOMAIN}/O=Homelab/C=US" \
  2>/dev/null

# --- 3. Sign the wildcard cert with our CA -----------------------------------
echo "  → Signing wildcard cert with local CA (valid ${DAYS_CERT} days)..."
cat > "$CERT_DIR/wildcard.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName=@alt_names

[alt_names]
DNS.1=*.${DOMAIN}
DNS.2=${DOMAIN}
EOF

openssl x509 -req \
  -in "$CERT_DIR/wildcard.csr" \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$WILDCARD_CERT" \
  -days "$DAYS_CERT" \
  -extfile "$CERT_DIR/wildcard.ext" \
  2>/dev/null

# --- Cleanup temp files -------------------------------------------------------
rm -f "$CERT_DIR/wildcard.csr" "$CERT_DIR/wildcard.ext" "$CERT_DIR/ca.srl"

# --- Done --------------------------------------------------------------------
echo ""
echo -e "${GREEN}✓${NC}  Certificates written to: core/traefik/certs/"
echo ""
echo "    ca.crt        ← Install this on every device (once)"
echo "    wildcard.crt  ← Traefik serves this for *.${DOMAIN}"
echo "    wildcard.key  ← Private key (keep safe, gitignored)"
echo "    ca.key        ← CA private key  (keep safe, gitignored)"
echo ""
echo -e "${BOLD}Device trust instructions:${NC}"
echo ""
echo "  Linux:   sudo cp core/traefik/certs/ca.crt /usr/local/share/ca-certificates/homeserver-ca.crt"
echo "           sudo update-ca-certificates"
echo ""
echo "  macOS:   open core/traefik/certs/ca.crt"
echo "           → Keychain Access → trust → Always Trust"
echo ""
echo "  Windows: Double-click ca.crt → Install → Trusted Root Certification Authorities"
echo ""
echo "  iOS:     AirDrop ca.crt to device → Settings → Profile Downloaded → Install"
echo "           → Settings → General → About → Certificate Trust Settings → Enable"
echo ""
echo "  Android: Settings → Security → Install certificate → CA certificate"
echo ""
