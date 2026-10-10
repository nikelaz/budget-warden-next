#!/usr/bin/env bash
# Regenerates the test certificate chain and signed JWS fixtures used by
# billing::apple tests. These certificates are for tests only and are never
# trusted outside them; the production root is the pinned Apple Root CA - G3.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ext_ca='basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign'
ext_leaf='basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature'

openssl ecparam -name prime256v1 -genkey -noout -out "$work/root.key"
openssl req -x509 -new -key "$work/root.key" -subj "/CN=Budget Warden Test Root" -days 7300 \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$work/root.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/inter.key"
openssl req -new -key "$work/inter.key" -subj "/CN=Budget Warden Test Intermediate" -out "$work/inter.csr"
printf '%s\n' "$ext_ca" > "$work/ca.ext"
openssl x509 -req -in "$work/inter.csr" -CA "$work/root.pem" -CAkey "$work/root.key" -CAcreateserial \
  -days 7300 -extfile "$work/ca.ext" -out "$work/inter.pem" 2>/dev/null

openssl ecparam -name prime256v1 -genkey -noout -out "$work/leaf.key"
openssl req -new -key "$work/leaf.key" -subj "/CN=Budget Warden Test Leaf" -out "$work/leaf.csr"
printf '%s\n' "$ext_leaf" > "$work/leaf.ext"
openssl x509 -req -in "$work/leaf.csr" -CA "$work/inter.pem" -CAkey "$work/inter.key" -CAcreateserial \
  -days 7300 -extfile "$work/leaf.ext" -out "$work/leaf.pem" 2>/dev/null

openssl x509 -in "$work/root.pem" -outform DER -out root.der
openssl x509 -in "$work/inter.pem" -outform DER -out intermediate.der
openssl x509 -in "$work/leaf.pem" -outform DER -out leaf.der

# Sign a sample StoreKit transaction with the leaf key, in the JWS form Apple
# uses: x5c carries leaf then intermediate, the signature is raw r||s.
expires_ms=$(( ($(date +%s) + 30*24*3600) * 1000 ))
signed_ms=$(( $(date +%s) * 1000 ))
leaf_b64=$(openssl x509 -in leaf.der -inform DER | awk '/BEGIN/{f=1;next}/END/{f=0}f' | tr -d '\n')
inter_b64=$(openssl x509 -in intermediate.der -inform DER | awk '/BEGIN/{f=1;next}/END/{f=0}f' | tr -d '\n')
header=$(printf '{"alg":"ES256","x5c":["%s","%s"]}' "$leaf_b64" "$inter_b64" | python3 -c 'import base64,sys;print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b"=").decode())')
payload=$(printf '{"originalTransactionId":"2000000000001","transactionId":"2000000000002","productId":"cloud.monthly","appAccountToken":"3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90","bundleId":"com.lazarovco.budgetwarden","expiresDate":%s,"signedDate":%s}' "$expires_ms" "$signed_ms" | python3 -c 'import base64,sys;print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b"=").decode())')
printf '%s.%s' "$header" "$payload" > "$work/signing-input"
openssl dgst -sha256 -sign "$work/leaf.key" -out "$work/signature.der" "$work/signing-input"
raw=$(python3 - "$work/signature.der" <<'PY'
import base64, sys
der = open(sys.argv[1], "rb").read()
def read_len(buf, i):
    n = buf[i]; i += 1
    if n & 0x80:
        k = n & 0x7f; n = int.from_bytes(buf[i:i+k], "big"); i += k
    return n, i
assert der[0] == 0x30
_, i = read_len(der, 1)
parts = []
for _ in range(2):
    assert der[i] == 0x02
    ln, j = read_len(der, i + 1)
    value = der[j:j+ln].lstrip(b"\x00").rjust(32, b"\x00")
    parts.append(value)
    i = j + ln
print(base64.urlsafe_b64encode(b"".join(parts)).rstrip(b"=").decode())
PY
)
printf '%s.%s' "$(cat "$work/signing-input")" "$raw" > signed_transaction.jws
echo "generated fixtures in $(pwd)"
