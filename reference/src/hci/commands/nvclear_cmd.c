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
 * Non-volatile settings commands (nvclear)
 *
 * The "nvclear" command returns the device to its factory state by
 * clearing the TOFU server fingerprint and trust anchor stored in
 * non-volatile storage (the EFI variable NVS backend).
 *
 */

#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <ipxe/command.h>
#include <ipxe/settings.h>
#include <ipxe/parseopt.h>
#include <ipxe/nvo.h>

/** Non-volatile settings cleared by "nvclear", in order */
static const char *nvclear_settings[] = {
	"server-fingerprint",
	"trust",
};

/**
 * The "nvclear" command
 *
 * @v argc		Argument count
 * @v argv		Argument list
 * @ret rc		Return status code
 *
 * Clears the settings stored in the non-volatile options block.  Each
 * setting is addressed by name and deleted from the "nvo" settings
 * block, so that the deletion reaches the underlying non-volatile
 * storage: deleting a bare setting name would only remove it from the
 * generic in-memory block, leaving the stored copy in place.
 */
static int nvclear_exec ( int argc, char **argv ) {
	struct settings *settings;
	struct named_setting setting;
	char name[32];
	unsigned int i;
	int rcx;
	int rc = 0;

	( void ) argc;
	( void ) argv;

	/* Locate non-volatile options block */
	settings = find_settings ( NVO_SETTINGS_NAME );
	if ( ! settings ) {
		printf ( "nvclear: no non-volatile settings\n" );
		return -ENODEV;
	}

	/* Clear each setting */
	for ( i = 0 ; i < ( sizeof ( nvclear_settings ) /
			    sizeof ( nvclear_settings[0] ) ) ; i++ ) {

		/* Parse setting name */
		snprintf ( name, sizeof ( name ), "%s", nvclear_settings[i] );
		if ( ( rcx = parse_setting_name ( name, NULL, &setting.settings,
						  &setting.setting ) ) != 0 ) {
			printf ( "nvclear: %s: %s\n", nvclear_settings[i],
				 strerror ( rcx ) );
			if ( ! rc )
				rc = rcx;
			continue;
		}

		/* Report absent settings, rather than claiming to clear them */
		if ( ! setting_exists ( settings, &setting.setting ) ) {
			printf ( "nvclear: %s: not present\n",
				 nvclear_settings[i] );
			continue;
		}

		/* Delete setting from non-volatile storage */
		if ( ( rcx = delete_setting ( settings,
					      &setting.setting ) ) != 0 ) {
			printf ( "nvclear: %s: could not clear: %s\n",
				 nvclear_settings[i], strerror ( rcx ) );
			if ( ! rc )
				rc = rcx;
			continue;
		}

		printf ( "nvclear: %s: cleared\n", nvclear_settings[i] );
	}

	/* Report result */
	if ( rc ) {
		printf ( "nvclear: incomplete\n" );
		return rc;
	}
	printf ( "nvclear: device NVRAM cleared\n" );

	return 0;
}

COMMAND ( nvclear, nvclear_exec );
