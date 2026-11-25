#include "machine_tls.h"
#include <stdlib.h>
#include <string.h>

#include <psa/crypto.h>
#include <mbedtls/pk.h>
#include <mbedtls/platform_util.h>

/* Large enough for a P-256 key or certificate in DER. */
#define DER_CAPACITY 2048

/* The DER writers fill the end of the buffer. Copies those bytes to a new buffer. */
static int take_der(const unsigned char *buffer, int written, unsigned char **out, size_t *length) {
  if (written < 0) return written;
  *out = malloc((size_t)written);
  if (!*out) return MBEDTLS_ERR_SSL_ALLOC_FAILED;
  memcpy(*out, buffer + DER_CAPACITY - written, (size_t)written);
  *length = (size_t)written;
  return 0;
}

int anvil_machine_tls_create(unsigned char **key, size_t *key_length, unsigned char **cert, size_t *cert_length) {
  *key = *cert = NULL;
  if (psa_crypto_init() != PSA_SUCCESS) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_type(&attributes, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
  psa_set_key_bits(&attributes, 256);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
  psa_set_key_algorithm(&attributes, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
  mbedtls_svc_key_id_t id = MBEDTLS_SVC_KEY_ID_INIT;
  if (psa_generate_key(&attributes, &id) != PSA_SUCCESS) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;

  mbedtls_pk_context pk;
  mbedtls_x509write_cert writer;
  mbedtls_pk_init(&pk);
  mbedtls_x509write_crt_init(&writer);
  unsigned char buffer[DER_CAPACITY], serial[16];
  int rc = mbedtls_pk_copy_from_psa(id, &pk);
  psa_destroy_key(id);
  if (rc != 0) goto done;
  /* The fingerprint identifies the certificate, so its fields need no meaning. */
  if (psa_generate_random(serial, sizeof(serial)) != PSA_SUCCESS) { rc = MBEDTLS_ERR_SSL_INTERNAL_ERROR; goto done; }
  serial[0] = (serial[0] & 0x7f) | 0x40;
  mbedtls_x509write_crt_set_version(&writer, MBEDTLS_X509_CRT_VERSION_3);
  mbedtls_x509write_crt_set_md_alg(&writer, MBEDTLS_MD_SHA256);
  mbedtls_x509write_crt_set_subject_key(&writer, &pk);
  mbedtls_x509write_crt_set_issuer_key(&writer, &pk);
  if ((rc = mbedtls_x509write_crt_set_subject_name(&writer, "CN=Anvil Machine")) != 0 ||
      (rc = mbedtls_x509write_crt_set_issuer_name(&writer, "CN=Anvil Machine")) != 0 ||
      (rc = mbedtls_x509write_crt_set_serial_raw(&writer, serial, sizeof(serial))) != 0 ||
      (rc = mbedtls_x509write_crt_set_validity(&writer, "20250101000000", "20991231235959")) != 0 ||
      (rc = mbedtls_x509write_crt_set_basic_constraints(&writer, 0, -1)) != 0)
    goto done;
  if ((rc = take_der(buffer, mbedtls_x509write_crt_der(&writer, buffer, sizeof(buffer)), cert, cert_length)) != 0)
    goto done;
  rc = take_der(buffer, mbedtls_pk_write_key_der(&pk, buffer, sizeof(buffer)), key, key_length);
done:
  mbedtls_platform_zeroize(buffer, sizeof(buffer));
  mbedtls_x509write_crt_free(&writer);
  mbedtls_pk_free(&pk);
  if (rc != 0) {
    free(*key);
    free(*cert);
    *key = *cert = NULL;
  }
  return rc;
}

int anvil_machine_tls_init(AnvilMachineTls *tls, const unsigned char *key, size_t key_length,
    const unsigned char *cert, size_t cert_length) {
  mbedtls_ssl_config_init(&tls->conf);
  mbedtls_x509_crt_init(&tls->cert);
  mbedtls_pk_init(&tls->key);
  tls->fingerprint[0] = 0;
  if (psa_crypto_init() != PSA_SUCCESS) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
  int rc;
  if ((rc = mbedtls_pk_parse_key(&tls->key, key, key_length, NULL, 0)) != 0 ||
      (rc = mbedtls_x509_crt_parse_der(&tls->cert, cert, cert_length)) != 0 ||
      (rc = mbedtls_ssl_config_defaults(&tls->conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM,
        MBEDTLS_SSL_PRESET_DEFAULT)) != 0 ||
      (rc = mbedtls_ssl_conf_own_cert(&tls->conf, &tls->cert, &tls->key)) != 0)
    return rc;
  /* Clients authenticate with their device token inside the link, not with certificates. */
  mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_NONE);
  if (!anvil_machine_tls_fingerprint(tls->cert.raw.p, tls->cert.raw.len, tls->fingerprint))
    return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
  return 0;
}

void anvil_machine_tls_free(AnvilMachineTls *tls) {
  mbedtls_ssl_config_free(&tls->conf);
  mbedtls_x509_crt_free(&tls->cert);
  mbedtls_pk_free(&tls->key);
}

bool anvil_machine_tls_fingerprint(const unsigned char *der, size_t length, char out[ANVIL_MACHINE_TLS_FINGERPRINT]) {
  unsigned char hash[32];
  size_t hash_length = 0;
  if (psa_crypto_init() != PSA_SUCCESS ||
      psa_hash_compute(PSA_ALG_SHA_256, der, length, hash, sizeof(hash), &hash_length) != PSA_SUCCESS ||
      hash_length != sizeof(hash))
    return false;
  static const char hex[] = "0123456789abcdef";
  for (size_t i = 0; i < sizeof(hash); i++) {
    out[i * 2] = hex[hash[i] >> 4];
    out[i * 2 + 1] = hex[hash[i] & 15];
  }
  out[64] = 0;
  return true;
}
