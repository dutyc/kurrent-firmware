/*
 * Copyright (C) 2026 kurrent-firmware project contributors.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of the
 * License, or any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301, USA.
 *
 * You can also choose to distribute this program under the terms of
 * the Unmodified Binary Distribution Licence (as given in the file
 * COPYING.UBDL), provided that you have satisfied its requirements.
 */

FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL );
FILE_SECBOOT ( PERMITTED );

/** @file
 *
 * TPM 2.0 attestation key commands (akgen, akpub, quote)
 *
 * The device identity is a restricted signing key held inside the
 * TPM.  "akgen" creates it on first boot and leaves it alone
 * afterwards; "akpub" exports the public half for the device report;
 * "quote" signs a control-plane nonce together with the PCR digest.
 *
 * All three commands need a TPM.  Without one they fail with
 * -ENODEV (or -ENOENT when the key has not been created), so a boot
 * script can take its no-TPM path; there is no software fallback.
 *
 * The exported settings exist for the current boot only: they are
 * stored in the in-memory settings root and never reach the EFI
 * variable NVS backend.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <ipxe/command.h>
#include <ipxe/settings.h>
#include <ipxe/dhcp.h>
#include <ipxe/base16.h>
#include <ipxe/efi/efi.h>
#include <ipxe/efi/efi_tpm2.h>

/** Attestation key public key setting */
static const struct setting ak_public_setting __setting ( SETTING_CRYPTO,
							  ak_public ) = {
	.name = "ak-public",
	.description = "TPM attestation key public key (SPKI DER)",
	.tag = DHCP_EB_AK_PUBLIC,
	.type = &setting_type_hexraw,
};

/** Attestation key name setting */
static const struct setting ak_name_setting __setting ( SETTING_CRYPTO,
							ak_name ) = {
	.name = "ak-name",
	.description = "TPM attestation key name (TPM2B_NAME)",
	.tag = DHCP_EB_AK_NAME,
	.type = &setting_type_hexraw,
};

/** Attestation key algorithm setting */
static const struct setting ak_type_setting __setting ( SETTING_CRYPTO,
							ak_type ) = {
	.name = "ak-type",
	.description = "TPM attestation key algorithm type",
	.tag = DHCP_EB_AK_TYPE,
	.type = &setting_type_string,
};

/** Secure Boot state setting */
static const struct setting sb_setting __setting ( SETTING_CRYPTO, sb ) = {
	.name = "sb",
	.description = "Secure Boot state (1 = enabled)",
	.tag = DHCP_EB_SB,
	.type = &setting_type_string,
};

/** Quote setting */
static const struct setting quote_setting __setting ( SETTING_CRYPTO,
						      quote ) = {
	.name = "quote",
	.description = "TPM quote (TPMS_ATTEST)",
	.tag = DHCP_EB_QUOTE,
	.type = &setting_type_hexraw,
};

/** Quote signature setting */
static const struct setting quote_sig_setting __setting ( SETTING_CRYPTO,
							  quote_sig ) = {
	.name = "quote-sig",
	.description = "TPM quote signature",
	.tag = DHCP_EB_QUOTE_SIG,
	.type = &setting_type_hexraw,
};

/**
 * Read the EFI Secure Boot state
 *
 * @ret sb		Secure Boot state (1 = enabled, 0 = disabled)
 *
 * The SecureBoot global variable is absent on platforms without
 * Secure Boot support and is otherwise set to 1 when enforcing.
 */
static int ak_secure_boot ( void ) {
	EFI_RUNTIME_SERVICES *rs = efi_systab->RuntimeServices;
	CHAR16 wname[] = L"SecureBoot";
	UINT8 value;
	UINTN size = sizeof ( value );
	UINT32 attrs;
	EFI_STATUS efirc;

	efirc = rs->GetVariable ( wname, &efi_global_variable, &attrs, &size,
				  &value );
	if ( ( efirc != 0 ) || ( size != sizeof ( value ) ) )
		return 0;

	return ( value ? 1 : 0 );
}

/**
 * Print a hex-encoded value
 *
 * @v label		Label
 * @v data		Raw value
 * @v len		Length of raw value
 */
static void ak_print ( const char *label, const void *data, size_t len ) {
	size_t encoded_len = ( base16_encoded_len ( len ) + 1 /* NUL */ );
	char *encoded;

	encoded = malloc ( encoded_len );
	if ( ! encoded ) {
		printf ( "%s: out of memory\n", label );
		return;
	}
	base16_encode ( data, len, encoded, encoded_len );
	printf ( "%s: %s\n", label, encoded );
	free ( encoded );
}

/**
 * Report an attestation key error
 *
 * @v command		Command name
 * @v rc		Return status code
 */
static void ak_error ( const char *command, int rc ) {

	if ( rc == -ENOENT ) {
		printf ( "%s: no attestation key (run akgen first)\n",
			 command );
	} else {
		printf ( "%s: %s\n", command, strerror ( rc ) );
	}
}

/**
 * The "akgen" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 *
 * Idempotent: the key is created on first use and reused afterwards.
 */
static int akgen_exec ( int argc, char **argv ) {
	int rc;

	( void ) argv;

	/* No arguments expected */
	if ( argc != 1 ) {
		printf ( "Usage: akgen\n" );
		return -EINVAL;
	}

	/* Create (or reuse) the attestation key */
	if ( ( rc = efi_tpm2_ak_create() ) != 0 ) {
		printf ( "akgen: %s\n", strerror ( rc ) );
		return rc;
	}
	printf ( "akgen: attestation key ready\n" );

	return 0;
}

/**
 * The "akpub" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 */
static int akpub_exec ( int argc, char **argv ) {
	const char *type_name;
	const char *sb;
	uint8_t spki[EFI_TPM2_SPKI_MAX];
	uint8_t name[EFI_TPM2_NAME_MAX];
	size_t spki_len = sizeof ( spki );
	size_t name_len = sizeof ( name );
	enum efi_tpm2_ak_type type;
	int rc;

	( void ) argv;

	/* No arguments expected */
	if ( argc != 1 ) {
		printf ( "Usage: akpub\n" );
		return -EINVAL;
	}

	/* Store Secure Boot state, which the report needs regardless of
	 * whether the key can be exported.
	 */
	sb = ( ak_secure_boot() ? "1" : "0" );
	if ( ( rc = store_setting ( NULL, &sb_setting, sb,
				    strlen ( sb ) ) ) != 0 )
		goto err_store;

	/* Export public key */
	if ( ( rc = efi_tpm2_ak_public ( spki, &spki_len, name, &name_len,
					 &type ) ) != 0 ) {
		printf ( "sb: %s\n", sb );
		ak_error ( "akpub", rc );
		return rc;
	}
	type_name = ( ( type == EFI_TPM2_AK_ECC_P256 ) ?
		      "ecc_p256" : "rsa2048" );

	/* Store settings for the boot script */
	if ( ( rc = store_setting ( NULL, &ak_public_setting, spki,
				    spki_len ) ) != 0 )
		goto err_store;
	if ( ( rc = store_setting ( NULL, &ak_name_setting, name,
				    name_len ) ) != 0 )
		goto err_store;
	if ( ( rc = store_setting ( NULL, &ak_type_setting, type_name,
				    strlen ( type_name ) ) ) != 0 )
		goto err_store;

	/* Report */
	printf ( "sb: %s\n", sb );
	ak_print ( "ak-public", spki, spki_len );
	ak_print ( "ak-name", name, name_len );
	printf ( "ak-type: %s\n", type_name );

	return 0;

 err_store:
	printf ( "akpub: could not store settings: %s\n", strerror ( rc ) );
	return rc;
}

/**
 * The "quote" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 *
 * Quotes PCR 0, 2, 4 and 7, with the nonce placed verbatim into
 * extraData.  The quote and its signature are also stored as settings
 * for the boot script.
 */
static int quote_exec ( int argc, char **argv ) {
	uint8_t attest[EFI_TPM2_QUOTE_MAX];
	uint8_t signature[EFI_TPM2_SIG_MAX];
	size_t attest_len = sizeof ( attest );
	size_t signature_len = sizeof ( signature );
	const char *nonce;
	size_t nonce_len;
	int rc;

	/* Require a nonce */
	if ( argc != 2 ) {
		printf ( "Usage: quote <nonce>\n" );
		return -EINVAL;
	}
	nonce = argv[1];
	nonce_len = strlen ( nonce );
	if ( ( nonce_len < 1 ) || ( nonce_len > 64 ) ) {
		printf ( "quote: nonce must be 1 to 64 bytes\n" );
		return -EINVAL;
	}

	/* Quote the PCRs */
	if ( ( rc = efi_tpm2_quote ( nonce, nonce_len, attest, &attest_len,
				     signature, &signature_len ) ) != 0 ) {
		ak_error ( "quote", rc );
		return rc;
	}

	/* Store settings for the boot script */
	if ( ( rc = store_setting ( NULL, &quote_setting, attest,
				    attest_len ) ) != 0 )
		goto err_store;
	if ( ( rc = store_setting ( NULL, &quote_sig_setting, signature,
				    signature_len ) ) != 0 )
		goto err_store;

	/* Report */
	ak_print ( "quote", attest, attest_len );
	ak_print ( "quote-sig", signature, signature_len );

	return 0;

 err_store:
	printf ( "quote: could not store settings: %s\n", strerror ( rc ) );
	return rc;
}

COMMAND ( akgen, akgen_exec );
COMMAND ( akpub, akpub_exec );
COMMAND ( quote, quote_exec );
