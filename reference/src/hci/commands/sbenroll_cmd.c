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
 * Secure Boot key enrollment command (sbenroll)
 *
 * Writes the platform key hierarchy into the firmware: PK first, then
 * KEK (signed by PK), then db (signed by KEK).  The three payloads
 * are generated at build time by build/sbenroll-gen.py and compiled
 * into the signed image; this command only submits them through
 * EFI_RUNTIME_SERVICES.SetVariable().
 *
 * The command is idempotent: when PK, KEK and db already hold our
 * descriptors nothing is written and the result is "ok".  A PK that
 * belongs to someone else leaves every variable untouched and yields
 * "foreign".  Any SetVariable() failure yields "failed".  The result
 * is published as the "sbenroll-result" setting for the boot script;
 * the command itself returns success in all of these cases so that a
 * failed enrollment cannot abort the phase script before it reports.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <ipxe/command.h>
#include <ipxe/settings.h>
#include <ipxe/dhcp.h>
#include <ipxe/efi/efi.h>
#include <ipxe/sbenroll_data.h>

/** Secure Boot enrollment result setting */
static const struct setting sbenroll_result_setting __setting ( SETTING_CRYPTO,
							       sbenroll_result ) = {
	.name = "sbenroll-result",
	.description = "Secure Boot key enrollment result",
	.tag = DHCP_EB_SBENROLL_RESULT,
	.type = &setting_type_string,
};

#if SBENROLL_ENROLL_DATA

/** Authenticated variable attributes used for PK/KEK/db */
#define SBENROLL_ATTRS ( EFI_VARIABLE_NON_VOLATILE |			\
			 EFI_VARIABLE_BOOTSERVICE_ACCESS |		\
			 EFI_VARIABLE_RUNTIME_ACCESS |			\
			 EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS )

/**
 * Read an EFI variable
 *
 * @v name		Variable name
 * @v data		Variable data to fill in (allocated)
 * @v len		Variable data length to fill in
 * @ret rc		Return status code (-ENOENT if absent)
 */
static int sbenroll_read ( const CHAR16 *name, const EFI_GUID *guid,
			   void **data, size_t *len ) {
	EFI_RUNTIME_SERVICES *rs = efi_systab->RuntimeServices;
	EFI_STATUS efirc;
	UINTN size = 0;
	UINT32 attrs = 0;
	void *buf;

	*data = NULL;
	*len = 0;

	/* Determine required size */
	efirc = rs->GetVariable ( ( CHAR16 * ) name, ( EFI_GUID * ) guid,
				  &attrs, &size, NULL );
	if ( efirc == EFI_NOT_FOUND )
		return -ENOENT;
	if ( efirc != EFI_BUFFER_TOO_SMALL )
		return -EEFI ( efirc );
	if ( size == 0 )
		return -ENOENT;

	/* Read variable */
	buf = malloc ( size );
	if ( ! buf )
		return -ENOMEM;
	efirc = rs->GetVariable ( ( CHAR16 * ) name, ( EFI_GUID * ) guid,
				  &attrs, &size, buf );
	if ( efirc != EFI_SUCCESS ) {
		free ( buf );
		return -EEFI ( efirc );
	}

	*data = buf;
	*len = size;
	return 0;
}

/**
 * Compare an EFI variable against a descriptor
 *
 * @v name		Variable name
 * @v esl		Expected EFI_SIGNATURE_LIST
 * @v len		Length of expected descriptor
 * @ret state		1 = matches, 0 = absent, -EEXIST = different
 * @ret rc		Return status code
 */
static int sbenroll_compare ( const CHAR16 *name, const EFI_GUID *guid,
			      const void *esl, size_t len ) {
	void *data;
	size_t data_len;
	int rc;

	if ( ( rc = sbenroll_read ( name, guid, &data, &data_len ) ) != 0 )
		return ( rc == -ENOENT ? 0 : rc );
	rc = ( ( data_len == len ) && ( memcmp ( data, esl, len ) == 0 ) ?
	       1 : -EEXIST );
	free ( data );
	return rc;
}

/**
 * Check whether an EFI variable contains a descriptor
 *
 * @v name		Variable name
 * @v guid		Variable vendor GUID
 * @v esl		EFI_SIGNATURE_LIST to look for
 * @v len		Length of descriptor
 * @ret present		Descriptor appears in the variable
 * @ret rc		Return status code
 *
 * The firmware may append further certificates to db, so presence,
 * not byte equality, decides whether another write is needed.
 */
static int sbenroll_contains ( const CHAR16 *name, const EFI_GUID *guid,
			       const void *esl, size_t len ) {
	void *data;
	size_t data_len;
	size_t i;
	int found = 0;
	int rc;

	if ( ( rc = sbenroll_read ( name, guid, &data, &data_len ) ) != 0 )
		return ( rc == -ENOENT ? 0 : rc );
	for ( i = 0 ; ( i + len ) <= data_len ; i++ ) {
		if ( memcmp ( ( ( uint8_t * ) data ) + i, esl, len ) == 0 ) {
			found = 1;
			break;
		}
	}
	free ( data );
	return found;
}

/**
 * Write an authenticated EFI variable
 *
 * @v name		Variable name
 * @v auth		EFI_VARIABLE_AUTHENTICATION_2 payload
 * @v len		Length of payload
 * @ret rc		Return status code
 */
static int sbenroll_write ( const char *what, const CHAR16 *name,
			    const EFI_GUID *guid, const void *auth,
			    size_t len ) {
	EFI_RUNTIME_SERVICES *rs = efi_systab->RuntimeServices;
	EFI_STATUS efirc;

	efirc = rs->SetVariable ( ( CHAR16 * ) name, ( EFI_GUID * ) guid,
				  SBENROLL_ATTRS, len, ( void * ) auth );
	if ( efirc != EFI_SUCCESS ) {
		printf ( "sbenroll: %s write: 0x%x%08x\n", what,
			 ( unsigned int ) ( efirc >> 32 ),
			 ( unsigned int ) efirc );
		return -EEFI ( efirc );
	}
	return 0;
}

/**
 * Enroll the platform key hierarchy
 *
 * @ret rc		0 = enrolled or already present, -EEXIST = foreign,
 *			other error = failed
 */
static int sbenroll_enroll ( int *wrote ) {
	int rc;

	*wrote = 0;

	/* PK: a foreign key blocks enrollment */
	rc = sbenroll_compare ( L"PK", &efi_global_variable,
				sbenroll_pk_esl,
				sizeof ( sbenroll_pk_esl ) );
	if ( rc < 0 )
		return rc;
	if ( rc == 0 ) {
		if ( ( rc = sbenroll_write ( "PK", L"PK", &efi_global_variable, sbenroll_pk_auth,
					     sizeof ( sbenroll_pk_auth ) ) )
		     != 0 )
			return rc;
		*wrote = 1;
	}

	/* KEK: write when absent or different (PK authorises it) */
	rc = sbenroll_compare ( L"KEK", &efi_global_variable,
				sbenroll_kek_esl,
				sizeof ( sbenroll_kek_esl ) );
	if ( rc < 0 && rc != -EEXIST )
		return rc;
	if ( rc != 1 ) {
		if ( ( rc = sbenroll_write ( "KEK", L"KEK", &efi_global_variable, sbenroll_kek_auth,
					     sizeof ( sbenroll_kek_auth ) ) )
		     != 0 )
			return rc;
		*wrote = 1;
	}

	/* db: write only when our descriptors are absent (KEK authorises) */
	rc = sbenroll_contains ( L"db", &efi_image_security_database_guid,
				 sbenroll_db_esl,
				 sizeof ( sbenroll_db_esl ) );
	if ( rc < 0 )
		return rc;
	if ( rc == 0 ) {
		if ( ( rc = sbenroll_write ( "db", L"db", &efi_image_security_database_guid,
					     sbenroll_db_auth,
					     sizeof ( sbenroll_db_auth ) ) )
		     != 0 )
			return rc;
		*wrote = 1;
	}

	return 0;
}

#endif /* SBENROLL_ENROLL_DATA */

/**
 * The "sbenroll" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 */
static int sbenroll_exec ( int argc, char **argv ) {
	const char *result;
	int wrote = 0;
	int rc;

	( void ) argv;

	if ( argc > 1 ) {
		printf ( "Usage: sbenroll\n" );
		return -EINVAL;
	}

#if SBENROLL_ENROLL_DATA
	rc = sbenroll_enroll ( &wrote );
#else
	rc = -ENOENT;
#endif
	if ( rc == 0 ) {
		result = "ok";
		printf ( wrote ? "sbenroll: ok (enrolled)\n" :
			 "sbenroll: ok (already enrolled)\n" );
	} else if ( rc == -EEXIST ) {
		result = "foreign";
		printf ( "sbenroll: foreign (a different PK is installed)\n" );
	} else {
		result = "failed";
		printf ( "sbenroll: failed: %s\n", strerror ( rc ) );
	}

	/* Publish the result for the boot script */
	if ( ( rc = store_setting ( NULL, &sbenroll_result_setting, result,
				    strlen ( result ) ) ) != 0 ) {
		printf ( "sbenroll: could not store result: %s\n",
			 strerror ( rc ) );
		return rc;
	}

	return 0;
}

COMMAND ( sbenroll, sbenroll_exec );
