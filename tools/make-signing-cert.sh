#!/bin/bash
# Crea (una sola vez) un certificado de code-signing autofirmado en el llavero
# para que PodsMute se firme con una identidad ESTABLE.
#
# Por que: con firma ad-hoc, macOS identifica la app ante TCC por el cdhash
# (el hash del binario), que cambia en cada rebuild -> el permiso de
# Accesibilidad (BannerKiller) se pierde en CADA recompilacion. Con una
# identidad estable el designated requirement pasa a ser
#   identifier "com.podsmute.app" and certificate leaf = H"<hash del cert>"
# que es constante entre rebuilds, asi que el permiso sobrevive.
#
# El cert es autofirmado: NO necesita cuenta de Apple Developer. Aparece como
# "not trusted" (CSSMERR_TP_NOT_TRUSTED) y eso es esperado y suficiente: TCC
# respeta el permiso que otorgas a mano; no exige una CA de confianza.
#
# Idempotente: si la identidad ya existe, no hace nada.
set -euo pipefail

CN="PodsMute Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$CN"; then
    echo "==> La identidad '$CN' ya existe. Nada que hacer."
    security find-identity -p codesigning | grep "$CN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PW="podsmute-local"   # password efimero solo para el p12 intermedio

cat > "$TMP/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = PodsMute Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Generando certificado autofirmado (10 anios, EKU=codeSigning)..."
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/pm.key" -out "$TMP/pm.crt" \
    -days 3650 -nodes -config "$TMP/cs.cnf" 2>/dev/null
# -passout con password concreto: LibreSSL genera un MAC que el importador de
# macOS rechaza si el password es vacio.
openssl pkcs12 -export -out "$TMP/pm.p12" -inkey "$TMP/pm.key" -in "$TMP/pm.crt" \
    -passout "pass:$PW" -name "$CN" 2>/dev/null

echo "==> Importando al llavero login (-A: codesign puede usarla sin prompts)..."
security import "$TMP/pm.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -A

echo "==> Listo. Identidad disponible:"
security find-identity -p codesigning | grep "$CN"
echo ""
echo "Siguiente: recompila con ./build-clt.sh y otorga Accesibilidad UNA ultima vez."
