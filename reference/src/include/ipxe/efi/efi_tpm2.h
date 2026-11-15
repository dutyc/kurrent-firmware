#ifndef _IPXE_EFI_TPM2_H
#define _IPXE_EFI_TPM2_H

/** @file
 *
 * TPM 2.0 attestation key and quote support (UEFI)
 *
 */

FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL );

#include <stdint.h>
#include <stddef.h>

/** Attestation key algorithms */
enum efi_tpm2_ak_type {
	/** ECC P-256 (restricted signing, ECDSA/SHA-256) */
	EFI_TPM2_AK_ECC_P256 = 0,
	/** RSA-2048 (restricted signing, RSASSA-PKCS1-v1_5/SHA-256) */
	EFI_TPM2_AK_RSA2048,
};

/** Maximum SubjectPublicKeyInfo length (RSA-2048) */
#define EFI_TPM2_SPKI_MAX 294

/** Maximum TPM2B_NAME length (SHA-256) */
#define EFI_TPM2_NAME_MAX 34

/** Maximum TPMS_ATTEST length */
#define EFI_TPM2_QUOTE_MAX 256

/** Maximum signature length (RSA-2048) */
#define EFI_TPM2_SIG_MAX 256

extern int efi_tpm2_ak_create ( int *created );
extern int efi_tpm2_ak_public ( uint8_t *spki, size_t *spki_len,
				uint8_t *name, size_t *name_len,
				enum efi_tpm2_ak_type *type );
extern int efi_tpm2_quote ( const void *nonce, size_t nonce_len,
			    void *quote, size_t *quote_len,
			    void *signature, size_t *signature_len );

#endif /* _IPXE_EFI_TPM2_H */
