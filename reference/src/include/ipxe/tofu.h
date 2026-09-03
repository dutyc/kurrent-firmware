#ifndef _IPXE_TOFU_H
#define _IPXE_TOFU_H

/** @file
 *
 * Trust On First Use (TOFU)
 *
 */

#include <ipxe/sha256.h>
#include <ipxe/x509.h>

/** Server leaf certificate fingerprint length (SHA-256) */
#define TOFU_FINGERPRINT_LEN SHA256_DIGEST_SIZE

extern int tofu_fingerprint_present ( void );
extern int tofu_store ( struct x509_certificate *cert );

#endif /* _IPXE_TOFU_H */
