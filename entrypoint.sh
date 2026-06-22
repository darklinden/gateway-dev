#!/bin/sh

export PATH="/root/.acme.sh:$PATH"

# Process nginx config template
envsubst '${DOMAIN}' </etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

# Native directory for dynamic configs — nginx glob on osxfs bind mounts segfaults on macOS
mkdir -p /etc/nginx/dynamic.d

# Create directories
mkdir -p /etc/nginx/ssl/${DOMAIN}
mkdir -p /certs/${DOMAIN}

# Sync conf.d (bind mount) to dynamic.d (native) — bypasses osxfs glob segfault
sync_confd() {
	rm -f /etc/nginx/dynamic.d/*.conf 2>/dev/null || true
	cp /etc/nginx/conf.d/*.conf /etc/nginx/dynamic.d/ 2>/dev/null || true
}

# Watch cert and conf.d changes, reload nginx when either changes
watch_and_reload() {
	CERT_FILE="/certs/${DOMAIN}/fullchain.pem"
	LAST_CERT_CHECKSUM=""
	LAST_CONFD_CHECKSUM=""

	while true; do
		# Check cert changes
		if [ -f "$CERT_FILE" ]; then
			CURRENT_CERT_CHECKSUM=$(md5sum "$CERT_FILE" 2>/dev/null | cut -d' ' -f1)
			if [ -n "$LAST_CERT_CHECKSUM" ] && [ "$CURRENT_CERT_CHECKSUM" != "$LAST_CERT_CHECKSUM" ]; then
				echo "Certificate changed, installing and reloading nginx..."
				cp /certs/${DOMAIN}/fullchain.pem /etc/nginx/ssl/${DOMAIN}/fullchain.pem
				cp /certs/${DOMAIN}/privkey.pem /etc/nginx/ssl/${DOMAIN}/key.pem
				nginx -s reload
				echo "Nginx reloaded with new certificate"
			fi
			LAST_CERT_CHECKSUM="$CURRENT_CERT_CHECKSUM"
		fi

		# Check conf.d changes
		CURRENT_CONFD_CHECKSUM=$(ls -lR /etc/nginx/conf.d/ 2>/dev/null | md5sum | cut -d' ' -f1)
		if [ -n "$LAST_CONFD_CHECKSUM" ] && [ "$CURRENT_CONFD_CHECKSUM" != "$LAST_CONFD_CHECKSUM" ]; then
			echo "conf.d changed, syncing and reloading nginx..."
			sync_confd
			if nginx -t 2>&1; then
				nginx -s reload
				echo "Nginx reloaded with new conf.d"
			else
				echo "nginx -t failed, skipping reload"
			fi
		fi
		LAST_CONFD_CHECKSUM="$CURRENT_CONFD_CHECKSUM"

		sleep 60
	done
}

# Function to register account (with optional EAB for non-Let's Encrypt CAs)
register_account() {
	if [ -n "${ACME_SERVER}" ] && [ -n "${EAB_KID}" ] && [ -n "${EAB_HMAC_KEY}" ]; then
		# Check if we already have local account data for this server
		SERVER_HASH=$(echo "${ACME_SERVER}" | md5sum | cut -d' ' -f1)
		if [ -d "/root/.acme.sh/ca/${SERVER_HASH}" ]; then
			echo "Account already registered locally, skipping."
			return 0
		fi

		echo "Registering account with EAB credentials for ${ACME_SERVER}..."
		if acme.sh --register-account \
			--server "${ACME_SERVER}" \
			--eab-kid "${EAB_KID}" \
			--eab-hmac-key "${EAB_HMAC_KEY}" 2>&1; then
			echo "Account registered successfully."
		else
			echo "WARNING: Account registration failed. EAB may have already been used."
			echo "  If the acme_data volume was deleted, you need new EAB credentials from the CA."
			echo "  nginx will continue serving with existing or self-signed certificates."
		fi
	fi
}

# Function to issue/renew certificate using acme.sh
issue_certificate() {
	echo "Issuing certificate for ${DOMAIN} and *.${DOMAIN} using acme.sh with Tencent DNS..."

	SERVER_OPTS=""
	if [ -n "${ACME_SERVER}" ]; then
		SERVER_OPTS="--server ${ACME_SERVER}"
	fi

	# Clean stale local state that can cause "authorization must be pending" from CA
	rm -rf /root/.acme.sh/${DOMAIN}_ecc /root/.acme.sh/${DOMAIN} 2>/dev/null || true

	if acme.sh --issue --dns dns_tencent -d "${DOMAIN}" -d "*.${DOMAIN}" \
		${SERVER_OPTS} \
		--keylength ec-256 \
		--dnssleep 60 \
		--force; then

		acme.sh --install-cert -d "${DOMAIN}" \
			--cert-file /certs/${DOMAIN}/cert.pem \
			--key-file /certs/${DOMAIN}/privkey.pem \
			--fullchain-file /certs/${DOMAIN}/fullchain.pem \
			--reloadcmd "nginx -s reload 2>/dev/null || true"
		return $?
	fi

	return 1
}

# Function to install certificate to nginx directory
install_certificate() {
	if [ -f "/certs/${DOMAIN}/fullchain.pem" ] && [ -f "/certs/${DOMAIN}/privkey.pem" ]; then
		echo "Installing certificate to nginx ssl directory..."
		cp /certs/${DOMAIN}/fullchain.pem /etc/nginx/ssl/${DOMAIN}/fullchain.pem
		cp /certs/${DOMAIN}/privkey.pem /etc/nginx/ssl/${DOMAIN}/key.pem
		echo "Certificate installed successfully"
		nginx -s reload 2>/dev/null && echo "Nginx reloaded with new certificate" || true
		return 0
	fi
	return 1
}

# Function to run the certificate renewal service
run_cert_service() {
	export Tencent_SecretId="${TENCENT_SECRET_ID}"
	export Tencent_SecretKey="${TENCENT_SECRET_KEY}"

	sleep 5

	register_account

	SERVER_OPTS=""
	if [ -n "${ACME_SERVER}" ]; then
		SERVER_OPTS="--server ${ACME_SERVER}"
	fi

	if [ -f "/certs/${DOMAIN}/fullchain.pem" ] && [ -f "/certs/${DOMAIN}/privkey.pem" ]; then
		echo "Existing certificates found, checking validity..."
		acme.sh --renew -d "${DOMAIN}" -d "*.${DOMAIN}" ${SERVER_OPTS} || true
		install_certificate
	else
		echo "No existing certificates, issuing new certificate..."
		if issue_certificate; then
			install_certificate
		else
			echo "Failed to issue certificate. Will retry in 1 hour."
		fi
	fi

	while true; do
		sleep 3600
		echo "Running scheduled certificate renewal check..."
		acme.sh --renew -d "${DOMAIN}" -d "*.${DOMAIN}" ${SERVER_OPTS} || true
		install_certificate
	done
}

# Check if we have existing certificates
if [ -f "/certs/${DOMAIN}/fullchain.pem" ] && [ -f "/certs/${DOMAIN}/privkey.pem" ]; then
	echo "Using existing certificates from /certs/${DOMAIN}/"
	cp /certs/${DOMAIN}/fullchain.pem /etc/nginx/ssl/${DOMAIN}/fullchain.pem
	cp /certs/${DOMAIN}/privkey.pem /etc/nginx/ssl/${DOMAIN}/key.pem
elif [ -f "/etc/nginx/ssl/${DOMAIN}/fullchain.pem" ]; then
	echo "Using existing certificates from /etc/nginx/ssl/${DOMAIN}/"
else
	echo "No certificates found. Generating self-signed certificate for initial startup..."
	cat > /tmp/openssl.cnf << OPENSSL_EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_req
prompt = no
[req_dn]
CN = ${DOMAIN}
[v3_req]
subjectAltName = DNS:${DOMAIN},DNS:*.${DOMAIN}
OPENSSL_EOF
	openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
		-keyout /etc/nginx/ssl/${DOMAIN}/key.pem \
		-out /etc/nginx/ssl/${DOMAIN}/fullchain.pem \
		-config /tmp/openssl.cnf
	rm -f /tmp/openssl.cnf
	echo "Self-signed certificate created. Will be replaced by ACME certificate."
fi

# Initial sync of conf.d to dynamic.d
sync_confd

# Start the certificate renewal service in background
run_cert_service &
CERT_SERVICE_PID=$!
echo "Certificate renewal service started (PID: $CERT_SERVICE_PID)"

# Start the nginx reload watcher in background
watch_and_reload &
WATCHER_PID=$!
echo "Config/cert watcher started (PID: $WATCHER_PID)"

# Handle shutdown gracefully
trap "kill $CERT_SERVICE_PID $WATCHER_PID 2>/dev/null; nginx -s quit" TERM INT

# Start nginx in foreground
exec nginx -g 'daemon off;'
