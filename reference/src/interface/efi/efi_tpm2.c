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
 * TPM 2.0 attestation key and quote support (UEFI)
 *
 * The attestation key (AK) is a restricted signing key that is
 * generated inside the TPM (TPM2_CreatePrimary), made persistent with
 * TPM2_EvictControl and thereafter reused.  Its private half never
 * leaves the TPM.
 *
 * TPM 2.0 commands are marshalled by hand and submitted through the
 * EFI_TCG2_PROTOCOL SubmitCommand() service, which is the only
 * standard EFI route to the TPM that does not pre-empt the platform
 * firmware's own use of the device.  The protocol exposes no Quote
 * operation, so TPM2_Quote is issued directly: the PCR digest and the
 * signature are then produced in a single TPM call, and no PCR can
 * change between reading and quoting.
 *
 * Everything here needs a TPM.  Without one (or without the TCG2
 * protocol) every operation fails with -ENODEV; there is no software
 * fallback.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ipxe/efi/efi.h>
#include <ipxe/efi/Protocol/Tcg2Protocol.h>
#include <ipxe/efi/efi_tpm2.h>

/** Persistent handle used for the attestation key */
#define EFI_TPM2_AK_HANDLE 0x81000001UL

/** Attestation key object attributes
 *
 * fixedTPM | fixedParent | sensitiveDataOrigin | userWithAuth |
 * restricted | sign
 */
#define EFI_TPM2_AK_ATTRIBUTES 0x00050072UL

/** TPM_ALG_RSA (not defined by the bundled Tpm20.h) */
#define EFI_TPM2_ALG_RSA 0x0001

/** TPM2B_NAME prefix for a SHA-256 name (TPM_ALG_SHA256) */
#define EFI_TPM2_NAME_SHA256 0x000b

/** PCR selection bitmap: PCR 0, 2, 4 and 7 */
static const uint8_t efi_tpm2_pcr_select[] = { 0x95, 0x00, 0x00 };

/** Maximum TPM2 command length */
#define EFI_TPM2_CMD_MAX 512

/** Maximum TPM2 response length */
#define EFI_TPM2_RESPONSE_MAX 4096

/** A TPM2 command under construction */
struct efi_tpm2_writer {
	/** Buffer */
	uint8_t *data;
	/** Buffer capacity */
	size_t cap;
	/** Current length */
	size_t len;
	/** Status code */
	int rc;
};

/** A TPM2 structure being parsed */
struct efi_tpm2_reader {
	/** Buffer */
	const uint8_t *data;
	/** Buffer length */
	size_t len;
	/** Current offset */
	size_t pos;
	/** Status code */
	int rc;
};

/** Parsed attestation key public area */
struct efi_tpm2_ak {
	/** TPM object type */
	uint16_t type;
	/** ECC public point (0x04 || X || Y) */
	uint8_t point[65];
	/** RSA modulus */
	uint8_t modulus[256];
	/** TPM2B_NAME */
	const uint8_t *name;
	/** TPM2B_NAME length */
	size_t name_len;
};

/** TCG2 protocol, or NULL if not located */
static EFI_TCG2_PROTOCOL *efi_tpm2_protocol;

/**
 * Locate the TCG2 protocol
 *
 * @ret rc		Return status code
 */
static int efi_tpm2_locate ( void ) {
	EFI_BOOT_SERVICES *bs = efi_systab->BootServices;
	EFI_TCG2_PROTOCOL *protocol;
	EFI_STATUS efirc;

	/* Reuse a previous successful lookup */
	if ( efi_tpm2_protocol )
		return 0;

	/* Locate protocol */
	if ( ( efirc = bs->LocateProtocol ( &efi_tcg2_protocol_guid, NULL,
					    ( ( void ** ) &protocol ) ) ) != 0 ){
		DBGC ( efi_tpm2_protocol, "TPM2 no TCG2 protocol: %s\n",
		       strerror ( -EEFI ( efirc ) ) );
		return -ENODEV;
	}
	efi_tpm2_protocol = protocol;
	DBGC ( efi_tpm2_protocol, "TPM2 found TCG2 protocol %p\n",
	       efi_tpm2_protocol );

	return 0;
}

/*****************************************************************************
 *
 * TPM2 command marshalling
 *
 *****************************************************************************
 */

/**
 * Append bytes to a command
 *
 * @v w			Command
 * @v data		Data
 * @v len		Length
 */
static void efi_tpm2_put ( struct efi_tpm2_writer *w, const void *data,
			   size_t len ) {

	/* Refuse to overflow the command buffer */
	if ( w->rc )
		return;
	if ( len > ( w->cap - w->len ) ) {
		w->rc = -ENOSPC;
		return;
	}
	memcpy ( ( w->data + w->len ), data, len );
	w->len += len;
}

/**
 * Append a single byte to a command
 *
 * @v w			Command
 * @v value		Value
 */
static void efi_tpm2_put_u8 ( struct efi_tpm2_writer *w, uint8_t value ) {

	efi_tpm2_put ( w, &value, sizeof ( value ) );
}

/**
 * Append a 16-bit big-endian value to a command
 *
 * @v w			Command
 * @v value		Value
 */
static void efi_tpm2_put_u16 ( struct efi_tpm2_writer *w, uint16_t value ) {
	uint8_t bytes[2];

	bytes[0] = ( value >> 8 );
	bytes[1] = value;
	efi_tpm2_put ( w, bytes, sizeof ( bytes ) );
}

/**
 * Append a 32-bit big-endian value to a command
 *
 * @v w			Command
 * @v value		Value
 */
static void efi_tpm2_put_u32 ( struct efi_tpm2_writer *w, uint32_t value ) {
	uint8_t bytes[4];

	bytes[0] = ( value >> 24 );
	bytes[1] = ( value >> 16 );
	bytes[2] = ( value >> 8 );
	bytes[3] = value;
	efi_tpm2_put ( w, bytes, sizeof ( bytes ) );
}

/**
 * Append an empty TPM2B to a command
 *
 * @v w			Command
 */
static void efi_tpm2_put_empty ( struct efi_tpm2_writer *w ) {

	efi_tpm2_put_u16 ( w, 0 );
}

/**
 * Append a password authorization session to a command
 *
 * @v w			Command
 */
static void efi_tpm2_put_password ( struct efi_tpm2_writer *w ) {

	efi_tpm2_put_u32 ( w, 1 );		/* Count */
	efi_tpm2_put_u32 ( w, TPM_RS_PW );	/* Session handle */
	efi_tpm2_put_empty ( w );		/* nonceCaller */
	efi_tpm2_put_u8 ( w, 0 );		/* sessionAttributes */
	efi_tpm2_put_empty ( w );		/* hmac */
}

/**
 * Open a command
 *
 * @v w			Command
 * @v tag		Command tag
 * @v code		Command code
 */
static void efi_tpm2_put_header ( struct efi_tpm2_writer *w, uint16_t tag,
				  uint32_t code ) {

	efi_tpm2_put_u16 ( w, tag );
	efi_tpm2_put_u32 ( w, 0 );	/* commandSize, patched below */
	efi_tpm2_put_u32 ( w, code );
}

/**
 * Close a command, filling in the commandSize
 *
 * @v w			Command
 */
static void efi_tpm2_put_trailer ( struct efi_tpm2_writer *w ) {
	size_t len = w->len;

	if ( w->rc )
		return;

	w->data[2] = ( len >> 24 );
	w->data[3] = ( len >> 16 );
	w->data[4] = ( len >> 8 );
	w->data[5] = len;
}

/*****************************************************************************
 *
 * TPM2 response parsing
 *
 *****************************************************************************
 */

/**
 * Extract bytes from a structure
 *
 * @v r			Reader
 * @v len		Length
 * @ret data		Data, or NULL on error
 */
static const void * efi_tpm2_get ( struct efi_tpm2_reader *r, size_t len ) {
	const void *data;

	if ( r->rc )
		return NULL;
	if ( len > ( r->len - r->pos ) ) {
		r->rc = -EIO;
		return NULL;
	}
	data = ( r->data + r->pos );
	r->pos += len;

	return data;
}

/**
 * Extract a 16-bit big-endian value from a structure
 *
 * @v r			Reader
 * @ret value		Value
 */
static uint16_t efi_tpm2_get_u16 ( struct efi_tpm2_reader *r ) {
	const uint8_t *bytes = efi_tpm2_get ( r, 2 );

	if ( ! bytes )
		return 0;

	return ( ( bytes[0] << 8 ) | bytes[1] );
}

/**
 * Extract a 32-bit big-endian value from a structure
 *
 * @v r			Reader
 * @ret value		Value
 */
static uint32_t efi_tpm2_get_u32 ( struct efi_tpm2_reader *r ) {
	const uint8_t *bytes = efi_tpm2_get ( r, 4 );

	if ( ! bytes )
		return 0;

	return ( ( bytes[0] << 24 ) | ( bytes[1] << 16 ) |
		 ( bytes[2] << 8 ) | bytes[3] );
}

/**
 * Extract a TPM2B from a structure
 *
 * @v r			Reader
 * @v len		Length to fill in
 * @ret data		Data, or NULL on error
 */
static const void * efi_tpm2_get_2b ( struct efi_tpm2_reader *r, size_t *len ) {
	const void *data;

	*len = efi_tpm2_get_u16 ( r );
	data = efi_tpm2_get ( r, *len );

	return data;
}

/**
 * Submit a command to the TPM
 *
 * @v cmd		Command
 * @v response		Response buffer to fill in (caller must free)
 * @v params		Response parameters
 * @ret rc		Return status code
 */
static int efi_tpm2_submit ( const struct efi_tpm2_writer *cmd,
			     uint8_t **response,
			     struct efi_tpm2_reader *params ) {
	uint32_t parameter_size;
	uint32_t response_code;
	EFI_STATUS efirc;
	uint8_t *data;
	int rc;

	/* Locate TCG2 protocol */
	if ( ( rc = efi_tpm2_locate() ) != 0 )
		return rc;

	/* Allocate response buffer */
	data = malloc ( EFI_TPM2_RESPONSE_MAX );
	if ( ! data )
		return -ENOMEM;
	memset ( data, 0, 10 );

	/* Submit command */
	if ( ( efirc = efi_tpm2_protocol->SubmitCommand ( efi_tpm2_protocol,
							  cmd->len, cmd->data,
							  EFI_TPM2_RESPONSE_MAX,
							  data ) ) != 0 ) {
		rc = -EEFI ( efirc );
		DBGC ( efi_tpm2_protocol, "TPM2 SubmitCommand failed: %s\n",
		       strerror ( rc ) );
		free ( data );
		return rc;
	}

	/* Parse response header */
	parameter_size = ( ( data[2] << 24 ) | ( data[3] << 16 ) |
			   ( data[4] << 8 ) | data[5] );
	response_code = ( ( data[6] << 24 ) | ( data[7] << 16 ) |
			  ( data[8] << 8 ) | data[9] );
	if ( response_code != 0 ) {
		DBGC ( efi_tpm2_protocol, "TPM2 command code %#08x failed: "
		       "%#08x\n",
		       ( ( cmd->data[6] << 24 ) | ( cmd->data[7] << 16 ) |
			 ( cmd->data[8] << 8 ) | cmd->data[9] ),
		       response_code );
		free ( data );

		/* A handle error means that the persistent object is
		 * absent (TPM_RC_HANDLE plus the handle index).
		 */
		if ( ( response_code & 0xbf ) == 0x8b )
			return -ENOENT;
		return -EIO;
	}
	if ( parameter_size > ( EFI_TPM2_RESPONSE_MAX - 10 ) ) {
		DBGC ( efi_tpm2_protocol, "TPM2 bad parameter size %d\n",
		       parameter_size );
		free ( data );
		return -EIO;
	}

	/* Return response */
	params->data = ( data + 10 );
	params->len = parameter_size;
	params->pos = 0;
	params->rc = 0;
	*response = data;

	return 0;
}

/*****************************************************************************
 *
 * Attestation key creation
 *
 *****************************************************************************
 */

/**
 * Build a CreatePrimary command
 *
 * @v w			Command
 * @v rsa		Use RSA-2048 instead of ECC P-256
 */
static void efi_tpm2_put_create_primary ( struct efi_tpm2_writer *w, int rsa ) {

	efi_tpm2_put_header ( w, TPM_ST_SESSIONS, TPM_CC_CreatePrimary );
	efi_tpm2_put_u32 ( w, TPM_RH_OWNER );
	efi_tpm2_put_password ( w );

	/* inSensitive: empty authValue and seedValue */
	efi_tpm2_put_u16 ( w, 4 );
	efi_tpm2_put_empty ( w );
	efi_tpm2_put_empty ( w );

	/* inPublic */
	if ( rsa ) {
		efi_tpm2_put_u16 ( w, 20 );
		efi_tpm2_put_u16 ( w, EFI_TPM2_ALG_RSA );
		efi_tpm2_put_u16 ( w, TPM_ALG_SHA256 );
		efi_tpm2_put_u32 ( w, EFI_TPM2_AK_ATTRIBUTES );
		efi_tpm2_put_empty ( w );	/* authPolicy */
		efi_tpm2_put_u16 ( w, TPM_ALG_NULL );	/* symmetric */
		efi_tpm2_put_empty ( w );	/* scheme */
		efi_tpm2_put_u16 ( w, 2048 );	/* keyBits */
		efi_tpm2_put_empty ( w );	/* exponent */
		efi_tpm2_put_empty ( w );	/* unique */
	} else {
		efi_tpm2_put_u16 ( w, 24 );
		efi_tpm2_put_u16 ( w, TPM_ALG_ECC );
		efi_tpm2_put_u16 ( w, TPM_ALG_SHA256 );
		efi_tpm2_put_u32 ( w, EFI_TPM2_AK_ATTRIBUTES );
		efi_tpm2_put_empty ( w );	/* authPolicy */
		efi_tpm2_put_u16 ( w, TPM_ALG_NULL );	/* symmetric */
		efi_tpm2_put_u16 ( w, TPM_ALG_ECDSA );	/* scheme */
		efi_tpm2_put_u16 ( w, TPM_ALG_SHA256 );
		efi_tpm2_put_u16 ( w, TPM_ECC_NIST_P256 );
		efi_tpm2_put_empty ( w );	/* kdf */
		efi_tpm2_put_empty ( w );	/* unique.x */
		efi_tpm2_put_empty ( w );	/* unique.y */
	}

	/* outsideInfo and creationPCR */
	efi_tpm2_put_empty ( w );
	efi_tpm2_put_u32 ( w, 0 );
}

/**
 * Create a primary attestation key
 *
 * @v rsa		Use RSA-2048 instead of ECC P-256
 * @ret handle		Transient object handle to fill in
 * @ret rc		Return status code
 */
static int efi_tpm2_create_primary ( int rsa, uint32_t *handle ) {
	uint8_t cmd[EFI_TPM2_CMD_MAX];
	struct efi_tpm2_writer w;
	struct efi_tpm2_reader params;
	uint8_t *response;
	int rc;

	/* Build command */
	memset ( &w, 0, sizeof ( w ) );
	w.data = cmd;
	w.cap = sizeof ( cmd );
	efi_tpm2_put_create_primary ( &w, rsa );
	if ( w.rc != 0 )
		return w.rc;
	efi_tpm2_put_trailer ( &w );

	/* Submit command */
	if ( ( rc = efi_tpm2_submit ( &w, &response, &params ) ) != 0 )
		return rc;

	/* Parse response */
	*handle = efi_tpm2_get_u32 ( &params );
	rc = params.rc;
	free ( response );

	return rc;
}

/**
 * Make a transient object persistent
 *
 * @v handle		Transient object handle
 * @ret rc		Return status code
 */
static int efi_tpm2_evict ( uint32_t handle ) {
	uint8_t cmd[EFI_TPM2_CMD_MAX];
	struct efi_tpm2_writer w;
	struct efi_tpm2_reader params;
	uint8_t *response;
	int rc;

	/* Build command */
	memset ( &w, 0, sizeof ( w ) );
	w.data = cmd;
	w.cap = sizeof ( cmd );
	efi_tpm2_put_header ( &w, TPM_ST_SESSIONS, TPM_CC_EvictControl );
	efi_tpm2_put_u32 ( &w, TPM_RH_OWNER );
	efi_tpm2_put_u32 ( &w, handle );
	efi_tpm2_put_password ( &w );
	efi_tpm2_put_u32 ( &w, EFI_TPM2_AK_HANDLE );
	if ( w.rc != 0 )
		return w.rc;
	efi_tpm2_put_trailer ( &w );

	/* Submit command */
	if ( ( rc = efi_tpm2_submit ( &w, &response, &params ) ) != 0 )
		return rc;

	/* Discard response */
	rc = params.rc;
	free ( response );

	return rc;
}

/**
 * Flush a transient object
 *
 * @v handle		Transient object handle
 */
static void efi_tpm2_flush ( uint32_t handle ) {
	uint8_t cmd[EFI_TPM2_CMD_MAX];
	struct efi_tpm2_writer w;
	struct efi_tpm2_reader params;
	uint8_t *response;
	int rc;

	/* Build command */
	memset ( &w, 0, sizeof ( w ) );
	w.data = cmd;
	w.cap = sizeof ( cmd );
	efi_tpm2_put_header ( &w, TPM_ST_NO_SESSIONS, TPM_CC_FlushContext );
	efi_tpm2_put_u32 ( &w, handle );
	if ( w.rc != 0 )
		return;
	efi_tpm2_put_trailer ( &w );

	/* Submit command, discarding any error */
	if ( ( rc = efi_tpm2_submit ( &w, &response, &params ) ) != 0 )
		return;
	free ( response );
}

/**
 * Read and parse the attestation key public area
 *
 * @v ak		Parsed public area to fill in
 * @v params		Response parameters to fill in
 * @v response		Response buffer to fill in (caller must free)
 * @ret rc		Return status code
 */
static int efi_tpm2_read_public ( struct efi_tpm2_ak *ak,
				  struct efi_tpm2_reader *params,
				  uint8_t **response ) {
	uint8_t cmd[EFI_TPM2_CMD_MAX];
	struct efi_tpm2_writer w;
	struct efi_tpm2_reader public;
	const uint8_t *data;
	size_t len;
	uint16_t scheme;
	uint16_t curve;
	const void *x;
	const void *y;
	size_t xlen;
	size_t ylen;
	int rc;

	/* Build command */
	memset ( &w, 0, sizeof ( w ) );
	w.data = cmd;
	w.cap = sizeof ( cmd );
	efi_tpm2_put_header ( &w, TPM_ST_NO_SESSIONS, TPM_CC_ReadPublic );
	efi_tpm2_put_u32 ( &w, EFI_TPM2_AK_HANDLE );
	if ( w.rc != 0 )
		return w.rc;
	efi_tpm2_put_trailer ( &w );

	/* Submit command */
	if ( ( rc = efi_tpm2_submit ( &w, response, params ) ) != 0 )
		return rc;

	/* Parse outPublic */
	memset ( ak, 0, sizeof ( *ak ) );
	data = efi_tpm2_get_2b ( params, &len );
	if ( ! data ) {
		rc = params->rc;
		goto err;
	}
	public.data = data;
	public.len = len;
	public.pos = 0;
	public.rc = 0;
	ak->type = efi_tpm2_get_u16 ( &public );
	if ( efi_tpm2_get_u16 ( &public ) != TPM_ALG_SHA256 ) {
		rc = -ENOTSUP;
		goto err;
	}
	efi_tpm2_get_u32 ( &public );		/* objectAttributes */
	efi_tpm2_get_2b ( &public, &len );	/* authPolicy */

	/* Parse type-specific parameters and unique area */
	if ( ak->type == TPM_ALG_ECC ) {
		efi_tpm2_get_u16 ( &public );	/* symmetric */
		scheme = efi_tpm2_get_u16 ( &public );
		if ( scheme != TPM_ALG_NULL )
			efi_tpm2_get_u16 ( &public );
		curve = efi_tpm2_get_u16 ( &public );
		efi_tpm2_get_2b ( &public, &len );	/* kdf */
		x = efi_tpm2_get_2b ( &public, &xlen );
		y = efi_tpm2_get_2b ( &public, &ylen );
		if ( public.rc != 0 ) {
			rc = public.rc;
			goto err;
		}
		if ( ( curve != TPM_ECC_NIST_P256 ) ||
		     ( xlen != 32 ) || ( ylen != 32 ) ) {
			rc = -ENOTSUP;
			goto err;
		}
		ak->point[0] = 0x04;
		memcpy ( &ak->point[1], x, 32 );
		memcpy ( &ak->point[33], y, 32 );
	} else if ( ak->type == EFI_TPM2_ALG_RSA ) {
		efi_tpm2_get_u16 ( &public );	/* symmetric */
		scheme = efi_tpm2_get_u16 ( &public );
		if ( scheme != TPM_ALG_NULL )
			efi_tpm2_get_u16 ( &public );
		efi_tpm2_get_u16 ( &public );	/* keyBits */
		efi_tpm2_get_2b ( &public, &len );	/* exponent */
		data = efi_tpm2_get_2b ( &public, &len );
		if ( public.rc != 0 ) {
			rc = public.rc;
			goto err;
		}
		if ( len != 256 ) {
			rc = -ENOTSUP;
			goto err;
		}
		memcpy ( ak->modulus, data, len );
	} else {
		rc = -ENOTSUP;
		goto err;
	}

	/* Parse name */
	ak->name = efi_tpm2_get_2b ( params, &ak->name_len );
	if ( ! ak->name ) {
		rc = params->rc;
		goto err;
	}
	if ( ( ak->name_len != ( 2 + 32 ) ) ||
	     ( ak->name[0] != 0x00 ) ||
	     ( ak->name[1] != EFI_TPM2_NAME_SHA256 ) ) {
		rc = -ENOTSUP;
		goto err;
	}

	return 0;

 err:
	free ( *response );
	*response = NULL;
	return rc;
}

/**
 * Create the persistent attestation key
 *
 * @ret rc		Return status code
 *
 * Idempotent: an existing attestation key is left untouched.  ECC
 * P-256 is preferred; RSA-2048 is used only if the TPM refuses ECC.
 */
int efi_tpm2_ak_create ( void ) {
	struct efi_tpm2_ak ak;
	struct efi_tpm2_reader params;
	uint8_t *response;
	uint32_t handle;
	int rc;

	/* Leave an existing key untouched */
	rc = efi_tpm2_read_public ( &ak, &params, &response );
	if ( rc == 0 ) {
		free ( response );
		DBGC ( efi_tpm2_protocol, "TPM2 attestation key already "
		       "present\n" );
		return 0;
	}
	if ( rc != -ENOENT )
		return rc;

	/* Create an ECC P-256 key in the TPM, falling back to RSA */
	if ( ( rc = efi_tpm2_create_primary ( 0, &handle ) ) != 0 ) {
		DBGC ( efi_tpm2_protocol, "TPM2 could not create ECC key: "
		       "%s\n", strerror ( rc ) );
		if ( ( rc = efi_tpm2_create_primary ( 1, &handle ) ) != 0 ) {
			DBGC ( efi_tpm2_protocol, "TPM2 could not create RSA "
			       "key: %s\n", strerror ( rc ) );
			return rc;
		}
	}

	/* Make the key persistent, then release the transient handle */
	rc = efi_tpm2_evict ( handle );
	efi_tpm2_flush ( handle );
	if ( rc != 0 ) {
		DBGC ( efi_tpm2_protocol, "TPM2 could not persist key: %s\n",
		       strerror ( rc ) );
		return rc;
	}
	DBGC ( efi_tpm2_protocol, "TPM2 attestation key created and "
	       "persisted\n" );

	return 0;
}

/**
 * Export the attestation key public key
 *
 * @v spki		SubjectPublicKeyInfo buffer to fill in
 * @v spki_len		Length of SubjectPublicKeyInfo
 * @v name		TPM2B_NAME buffer to fill in
 * @v name_len		Length of TPM2B_NAME
 * @v type		Algorithm type to fill in
 * @ret rc		Return status code
 */
int efi_tpm2_ak_public ( uint8_t *spki, size_t *spki_len,
			 uint8_t *name, size_t *name_len,
			 enum efi_tpm2_ak_type *type ) {
	static const uint8_t ecc_prefix[] = {
		0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48,
		0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
		0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
	};
	static const uint8_t rsa_prefix[] = {
		0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a,
		0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
		0x00, 0x03, 0x82, 0x01, 0x0f, 0x00, 0x30, 0x82, 0x01,
		0x0a, 0x02, 0x82, 0x01, 0x01, 0x00,
	};
	static const uint8_t rsa_suffix[] = {
		0x02, 0x03, 0x01, 0x00, 0x01,
	};
	struct efi_tpm2_ak ak;
	struct efi_tpm2_reader params;
	uint8_t *response;
	size_t len;
	int rc;

	/* Read public area */
	if ( ( rc = efi_tpm2_read_public ( &ak, &params, &response ) ) != 0 )
		return rc;

	/* Construct SubjectPublicKeyInfo */
	if ( ak.type == TPM_ALG_ECC ) {
		len = ( sizeof ( ecc_prefix ) + sizeof ( ak.point ) );
		if ( len > *spki_len ) {
			rc = -ENOSPC;
			goto done;
		}
		memcpy ( spki, ecc_prefix, sizeof ( ecc_prefix ) );
		memcpy ( &spki[sizeof ( ecc_prefix )], ak.point,
			 sizeof ( ak.point ) );
		*type = EFI_TPM2_AK_ECC_P256;
	} else {
		len = ( sizeof ( rsa_prefix ) + sizeof ( ak.modulus ) +
			sizeof ( rsa_suffix ) );
		if ( len > *spki_len ) {
			rc = -ENOSPC;
			goto done;
		}
		memcpy ( spki, rsa_prefix, sizeof ( rsa_prefix ) );
		memcpy ( &spki[sizeof ( rsa_prefix )], ak.modulus,
			 sizeof ( ak.modulus ) );
		memcpy ( &spki[ sizeof ( rsa_prefix ) +
				sizeof ( ak.modulus ) ], rsa_suffix,
			 sizeof ( rsa_suffix ) );
		*type = EFI_TPM2_AK_RSA2048;
	}
	*spki_len = len;

	/* Copy TPM2B_NAME */
	if ( ak.name_len > *name_len ) {
		rc = -ENOSPC;
		goto done;
	}
	memcpy ( name, ak.name, ak.name_len );
	*name_len = ak.name_len;

	rc = 0;

 done:
	free ( response );
	return rc;
}

/*****************************************************************************
 *
 * Quote
 *
 *****************************************************************************
 */

/**
 * Encode an ECDSA signature integer (DER)
 *
 * @v out		Output buffer
 * @v value		Integer value
 * @v len		Length of integer value
 * @ret len		Length of DER encoding
 */
static size_t efi_tpm2_put_der_integer ( uint8_t *out, const uint8_t *value,
					 size_t len ) {

	/* Strip leading zeroes, keeping at least one octet */
	while ( ( len > 1 ) && ( value[0] == 0 ) ) {
		value++;
		len--;
	}

	/* Prefix an extra zero octet if the value is negative */
	out[0] = 0x02;
	if ( value[0] & 0x80 ) {
		out[1] = ( len + 1 );
		out[2] = 0x00;
		memcpy ( &out[3], value, len );
		return ( 3 + len );
	}
	out[1] = len;
	memcpy ( &out[2], value, len );

	return ( 2 + len );
}

/**
 * Encode an ECDSA signature (DER)
 *
 * @v out		Output buffer
 * @v out_len		Length of output buffer to fill in
 * @v r			Signature r value
 * @v r_len		Length of r
 * @v s			Signature s value
 * @v s_len		Length of s
 * @ret rc		Return status code
 */
static int efi_tpm2_put_der_signature ( uint8_t *out, size_t *out_len,
					const uint8_t *r, size_t r_len,
					const uint8_t *s, size_t s_len ) {
	uint8_t body[80];
	size_t r_encoded;
	size_t s_encoded;
	size_t content;

	/* Sanity check */
	if ( ( r_len < 1 ) || ( r_len > 33 ) ||
	     ( s_len < 1 ) || ( s_len > 33 ) )
		return -EIO;

	/* Encode integers */
	r_encoded = efi_tpm2_put_der_integer ( body, r, r_len );
	s_encoded = efi_tpm2_put_der_integer ( ( body + r_encoded ), s, s_len );
	content = ( r_encoded + s_encoded );
	if ( content > 0x7f )
		return -EIO;

	/* Encode sequence */
	if ( ( 2 + content ) > *out_len )
		return -ENOSPC;
	out[0] = 0x30;
	out[1] = content;
	memcpy ( &out[2], body, content );
	*out_len = ( 2 + content );

	return 0;
}


/**
 * Quote PCR 0, 2, 4 and 7 with the attestation key
 *
 * @v nonce		Qualifying data
 * @v nonce_len		Length of qualifying data
 * @v quote		TPMS_ATTEST buffer to fill in
 * @v quote_len		Length of TPMS_ATTEST
 * @v signature		Signature buffer to fill in
 * @v signature_len	Length of signature
 * @ret rc		Return status code
 *
 * The PCR digest and the signature are produced by a single TPM call,
 * so no PCR can change in between.  The qualifying data is placed in
 * extraData verbatim.
 */
int efi_tpm2_quote ( const void *nonce, size_t nonce_len,
		     void *quote, size_t *quote_len,
		     void *signature, size_t *signature_len ) {
	uint8_t cmd[EFI_TPM2_CMD_MAX];
	struct efi_tpm2_writer w;
	struct efi_tpm2_reader params;
	struct efi_tpm2_ak ak;
	uint8_t *response;
	const uint8_t *attest;
	const void *r;
	const void *s;
	size_t attest_len;
	size_t r_len;
	size_t s_len;
	size_t len;
	uint16_t algorithm;
	int rc;

	/* Sanity check */
	if ( ( nonce_len < 1 ) || ( nonce_len > 64 ) )
		return -EINVAL;

	/* Determine the signature algorithm from the AK */
	if ( ( rc = efi_tpm2_read_public ( &ak, &params, &response ) ) != 0 )
		return rc;
	free ( response );

	/* Build command */
	memset ( &w, 0, sizeof ( w ) );
	w.data = cmd;
	w.cap = sizeof ( cmd );
	efi_tpm2_put_header ( &w, TPM_ST_SESSIONS, TPM_CC_Quote );
	efi_tpm2_put_u32 ( &w, EFI_TPM2_AK_HANDLE );
	efi_tpm2_put_password ( &w );
	efi_tpm2_put_u16 ( &w, nonce_len );
	efi_tpm2_put ( &w, nonce, nonce_len );
	efi_tpm2_put_u16 ( &w, ( ( ak.type == TPM_ALG_ECC ) ?
				 TPM_ALG_ECDSA : TPM_ALG_RSASSA ) );
	efi_tpm2_put_u16 ( &w, TPM_ALG_SHA256 );
	efi_tpm2_put_u32 ( &w, 1 );		/* Selection count */
	efi_tpm2_put_u16 ( &w, TPM_ALG_SHA256 );
	efi_tpm2_put_u8 ( &w, sizeof ( efi_tpm2_pcr_select ) );
	efi_tpm2_put ( &w, efi_tpm2_pcr_select,
		       sizeof ( efi_tpm2_pcr_select ) );
	if ( w.rc != 0 )
		return w.rc;
	efi_tpm2_put_trailer ( &w );

	/* Submit command */
	if ( ( rc = efi_tpm2_submit ( &w, &response, &params ) ) != 0 )
		return rc;

	/* Parse quotation */
	attest = efi_tpm2_get_2b ( &params, &attest_len );
	algorithm = efi_tpm2_get_u16 ( &params );
	efi_tpm2_get_u16 ( &params );		/* hash algorithm */
	if ( params.rc != 0 ) {
		rc = params.rc;
		goto done;
	}
	if ( ( algorithm != ( ( ak.type == TPM_ALG_ECC ) ?
			       TPM_ALG_ECDSA : TPM_ALG_RSASSA ) ) ) {
		rc = -EIO;
		goto done;
	}
	if ( attest_len > *quote_len ) {
		rc = -ENOSPC;
		goto done;
	}
	memcpy ( quote, attest, attest_len );
	*quote_len = attest_len;

	/* Encode signature */
	if ( ak.type == TPM_ALG_ECC ) {

		/* Convert (r, s) to an ASN.1 DER sequence */
		r = efi_tpm2_get_2b ( &params, &r_len );
		s = efi_tpm2_get_2b ( &params, &s_len );
		if ( params.rc != 0 ) {
			rc = params.rc;
			goto done;
		}
		if ( ( rc = efi_tpm2_put_der_signature ( signature,
							 signature_len,
							 r, r_len,
							 s, s_len ) ) != 0 )
			goto done;
	} else {

		/* Raw PKCS#1 v1.5 signature */
		r = efi_tpm2_get_2b ( &params, &len );
		if ( params.rc != 0 ) {
			rc = params.rc;
			goto done;
		}
		if ( len > *signature_len ) {
			rc = -ENOSPC;
			goto done;
		}
		memcpy ( signature, r, len );
		*signature_len = len;
	}

	rc = 0;

 done:
	free ( response );
	return rc;
}
