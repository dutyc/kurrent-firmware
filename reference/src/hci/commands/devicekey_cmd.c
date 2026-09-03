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
 * Device identity key commands (keygen, pubkey, sign)
 *
 * These commands manage the device identity key stored in non-volatile
 * storage (the "device-key" setting, backed by the EFI variable NVS
 * backend):
 *
 *  - "keygen" generates a fresh ECDSA P-256 private key (seeded from
 *    the EFI RNG entropy source via the DRBG mechanism) and stores it
 *    in non-volatile storage.  The private key never leaves the
 *    device.
 *
 *  - "pubkey" derives the corresponding public key and displays it as
 *    a hex-encoded uncompressed curve point, also storing it in the
 *    "pubkey" setting for use by scripts.
 *
 *  - "sign" signs a data string (e.g. nonce||mac||hostname) with the
 *    device key and displays the base64-encoded DER signature, also
 *    storing it in the "sig" setting for use by scripts.
 *
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <ipxe/command.h>
#include <ipxe/settings.h>
#include <ipxe/nvo.h>
#include <ipxe/dhcp.h>
#include <ipxe/drbg.h>
#include <ipxe/p256.h>
#include <ipxe/ecdsa.h>
#include <ipxe/asn1.h>
#include <ipxe/crypto.h>
#include <ipxe/sha256.h>
#include <ipxe/base64.h>

/** Device identity private key setting (EFI variable NVS backend) */
extern const struct setting device_key_setting;

/** Derived public key setting (temporary, for use by scripts) */
static const struct setting pubkey_setting __setting ( SETTING_CRYPTO,
						      pubkey ) = {
	.name = "pubkey",
	.description = "Device public key (uncompressed point, hex)",
	.tag = DHCP_EB_PUBKEY,
	.type = &setting_type_hexraw,
};

/** Generated signature setting (temporary, for use by scripts) */
static const struct setting sig_setting __setting ( SETTING_CRYPTO, sig ) = {
	.name = "sig",
	.description = "Device signature (base64-encoded DER)",
	.tag = DHCP_EB_SIG,
	.type = &setting_type_string,
};

/** "prime256v1" object identifier (1.2.840.10045.3.1.7) */
static const uint8_t oid_prime256v1[] = {
	0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07
};

/**
 * Locate non-volatile options settings block
 *
 * @ret settings	Settings block, or NULL
 */
static struct settings * devicekey_settings ( void ) {
	return find_settings ( NVO_SETTINGS_NAME );
}

/**
 * Fetch device private key from non-volatile storage
 *
 * @v priv		Private key to fill in
 * @ret rc		Return status code
 */
static int devicekey_fetch ( uint8_t *priv ) {
	return fetch_raw_setting ( NULL, &device_key_setting, priv, P256_LEN );
}

/**
 * Derive public key from private key
 *
 * @v priv		Private key
 * @v pub		Public key (uncompressed curve point) to fill in
 * @ret rc		Return status code
 */
static int devicekey_pubkey ( const uint8_t *priv, uint8_t *pub ) {

	pub[0] = ELLIPTIC_FORMAT_UNCOMPRESSED;
	return p256_curve.multiply ( &p256_curve, p256_curve.base, priv,
				     &pub[1] );
}

/**
 * The "keygen" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 */
static int keygen_exec ( int argc, char **argv ) {
	struct settings *settings;
	struct drbg_state drbg;
	uint8_t priv[P256_LEN];
	uint8_t zero[P256_LEN] = { 0 };
	int rc;

	( void ) argc;
	( void ) argv;

	/* Refuse to overwrite an existing key */
	if ( setting_exists ( NULL, &device_key_setting ) ) {
		printf ( "keygen: device key already exists\n" );
		return -EEXIST;
	}

	/* Generate private key using DRBG (seeded from EFI RNG) */
	if ( ( rc = drbg_instantiate ( &drbg, NULL, 0 ) ) != 0 ) {
		printf ( "keygen: could not instantiate DRBG: %s\n",
			 strerror ( rc ) );
		return rc;
	}
	do {
		if ( ( rc = drbg_generate ( &drbg, NULL, 0, 0, priv,
					    sizeof ( priv ) ) ) != 0 ) {
			printf ( "keygen: could not generate key: %s\n",
				 strerror ( rc ) );
			drbg_uninstantiate ( &drbg );
			return rc;
		}
	} while ( memcmp ( priv, zero, sizeof ( zero ) ) == 0 );
	drbg_uninstantiate ( &drbg );

	/* Store private key in non-volatile storage */
	settings = devicekey_settings();
	if ( ! settings ) {
		printf ( "keygen: no non-volatile settings\n" );
		return -ENODEV;
	}
	if ( ( rc = store_setting ( settings, &device_key_setting,
				    priv, sizeof ( priv ) ) ) != 0 ) {
		printf ( "keygen: could not store device key: %s\n",
			 strerror ( rc ) );
		return rc;
	}

	printf ( "keygen: device key generated\n" );
	return 0;
}

/**
 * The "pubkey" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 */
static int pubkey_exec ( int argc, char **argv ) {
	uint8_t priv[P256_LEN];
	uint8_t pub[1 + P256_LEN * 2];
	unsigned int i;
	int rc;

	( void ) argc;
	( void ) argv;

	/* Fetch device key */
	if ( ( rc = devicekey_fetch ( priv ) ) < 0 ) {
		printf ( "pubkey: no device key (run keygen first)\n" );
		return rc;
	}

	/* Derive public key */
	if ( ( rc = devicekey_pubkey ( priv, pub ) ) != 0 ) {
		printf ( "pubkey: could not derive public key: %s\n",
			 strerror ( rc ) );
		return rc;
	}

	/* Store as setting (hex) for use by scripts */
	if ( ( rc = store_setting ( NULL, &pubkey_setting, pub,
				    sizeof ( pub ) ) ) != 0 ) {
		printf ( "pubkey: could not store public key: %s\n",
			 strerror ( rc ) );
		return rc;
	}

	/* Print hex-encoded uncompressed point */
	for ( i = 0 ; i < sizeof ( pub ) ; i++ )
		printf ( "%02x", pub[i] );
	printf ( "\n" );
	return 0;
}

/**
 * The "sign" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 */
static int sign_exec ( int argc, char **argv ) {
	struct digest_algorithm *digest = &sha256_algorithm;
	struct asn1_builder key = { NULL, 0 };
	struct asn1_builder params = { NULL, 0 };
	struct asn1_builder pubkey = { NULL, 0 };
	struct asn1_builder signature = { NULL, 0 };
	uint8_t priv[P256_LEN];
	uint8_t pub[1 + P256_LEN * 2];
	uint8_t pub_bits[1 + sizeof ( pub )];
	uint8_t ctx[digest->ctxsize];
	uint8_t digest_out[digest->digestsize];
	uint8_t version = 1;
	char *encoded;
	size_t encoded_len;
	int i;
	int rc;

	/* Require data to be signed */
	if ( argc < 2 ) {
		printf ( "Usage: sign <data...>\n" );
		return -EINVAL;
	}

	/* Fetch device key */
	if ( ( rc = devicekey_fetch ( priv ) ) < 0 ) {
		printf ( "sign: no device key (run keygen first)\n" );
		return rc;
	}

	/* Derive public key */
	if ( ( rc = devicekey_pubkey ( priv, pub ) ) != 0 ) {
		printf ( "sign: could not derive public key: %s\n",
			 strerror ( rc ) );
		return rc;
	}

	/* Construct SEC1 ECPrivateKey (including the public key, which
	 * the parser requires).  Each wrap encloses the entire current
	 * builder contents, so nested sibling elements ([0] and [1])
	 * must be built in separate builders and then assembled.
	 */
	pub_bits[0] = 0; /* no unused bits */
	memcpy ( &pub_bits[1], pub, sizeof ( pub ) );
	if ( ( rc = ( asn1_prepend_raw ( &pubkey, pub_bits,
					 sizeof ( pub_bits ) ),
		      asn1_wrap ( &pubkey, ASN1_BIT_STRING ),
		      asn1_wrap ( &pubkey, ASN1_EXPLICIT_TAG ( 1 ) ),
		      asn1_prepend_raw ( &params, oid_prime256v1,
					 sizeof ( oid_prime256v1 ) ),
		      asn1_wrap ( &params, ASN1_EXPLICIT_TAG ( 0 ) ),
		      asn1_prepend_raw ( &key, pubkey.data, pubkey.len ),
		      asn1_prepend_raw ( &key, params.data, params.len ),
		      asn1_prepend ( &key, ASN1_OCTET_STRING, priv,
				     sizeof ( priv ) ),
		      asn1_prepend ( &key, ASN1_INTEGER, &version,
				     sizeof ( version ) ),
		      asn1_wrap ( &key, ASN1_SEQUENCE ) ) ) != 0 ) {
		printf ( "sign: could not construct key: %s\n",
			 strerror ( rc ) );
		goto err_key;
	}

	/* Digest the data to be signed (arguments concatenated without
	 * separators)
	 */
	digest_init ( digest, ctx );
	for ( i = 1 ; i < argc ; i++ )
		digest_update ( digest, ctx, argv[i], strlen ( argv[i] ) );
	digest_final ( digest, ctx, digest_out );

	/* Sign digest */
	if ( ( rc = pubkey_sign ( &ecdsa_algorithm, asn1_built ( &key ),
				  digest, digest_out, &signature ) ) != 0 ) {
		printf ( "sign: could not sign: %s\n", strerror ( rc ) );
		goto err_sign;
	}

	/* Base64-encode signature */
	encoded_len = ( base64_encoded_len ( signature.len ) + 1 /* NUL */ );
	encoded = zalloc ( encoded_len );
	if ( ! encoded ) {
		rc = -ENOMEM;
		goto err_alloc;
	}
	base64_encode ( signature.data, signature.len, encoded, encoded_len );

	/* Store as setting for use by scripts */
	if ( ( rc = store_setting ( NULL, &sig_setting, encoded,
				    strlen ( encoded ) ) ) != 0 ) {
		printf ( "sign: could not store signature: %s\n",
			 strerror ( rc ) );
		goto err_store;
	}

	/* Print base64-encoded signature */
	printf ( "%s\n", encoded );

 err_store:
	free ( encoded );
 err_alloc:
	free ( signature.data );
 err_sign:
	free ( key.data );
	free ( params.data );
	free ( pubkey.data );
 err_key:
	return rc;
}

COMMAND ( keygen, keygen_exec );
COMMAND ( pubkey, pubkey_exec );
COMMAND ( sign, sign_exec );
