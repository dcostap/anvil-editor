#ifndef ANVIL_MACHINE_TLS_H
#define ANVIL_MACHINE_TLS_H
#include <stdbool.h>
#include <stddef.h>

#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

/* TLS for Machine links. A Machine server has one self-signed certificate. A paired Client
 * pins the SHA-256 fingerprint of that certificate, so no certificate authority is needed.
 * This file has no Lua headers. */
#define ANVIL_MACHINE_TLS_FINGERPRINT 65

typedef struct AnvilMachineTls {
  mbedtls_ssl_config conf;
  mbedtls_x509_crt cert;
  mbedtls_pk_context key;
  char fingerprint[ANVIL_MACHINE_TLS_FINGERPRINT];
} AnvilMachineTls;

/* Makes a new P-256 key and a self-signed certificate for it, both in DER. The caller frees
 * both buffers with free(). Returns 0, or an mbedtls error code. */
int anvil_machine_tls_create(unsigned char **key, size_t *key_length, unsigned char **cert, size_t *cert_length);

/* Prepares a server TLS configuration from the DER key and certificate. Returns 0, or an mbedtls
 * error code. Call anvil_machine_tls_free() in both cases. */
int anvil_machine_tls_init(AnvilMachineTls *tls, const unsigned char *key, size_t key_length,
    const unsigned char *cert, size_t cert_length);
void anvil_machine_tls_free(AnvilMachineTls *tls);

/* Writes the lowercase hex SHA-256 of a DER certificate. Returns false when hashing fails. */
bool anvil_machine_tls_fingerprint(const unsigned char *der, size_t length, char out[ANVIL_MACHINE_TLS_FINGERPRINT]);

#endif
