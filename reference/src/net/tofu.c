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
 * Trust On First Use (TOFU)
 *
 * During the registration window (first boot, before any fingerprint
 * has been stored in non-volatile storage), a TLS handshake with an
 * otherwise-untrusted server certificate is accepted and the leaf
 * certificate SHA-256 fingerprint is stored in non-volatile storage,
 * both as the "server-fingerprint" setting and as the "trust" setting
 * (which the root certificate initialiser reads into the root
 * certificate store on the next boot).  Once a fingerprint is
 * present, TLS validation failures are fatal, so a changed server
 * certificate is rejected.
 *
 */

#include <string.h>
#include <errno.h>
#include <ipxe/sha256.h>
#include <ipxe/settings.h>
#include <ipxe/x509.h>
#include <ipxe/dhcp.h>
#include <ipxe/nvo.h>
#include <ipxe/tofu.h>

/** Server certificate fingerprint setting (EFI variable NVS backend) */
extern const struct setting server_fingerprint_setting;

/** Trusted root certificate fingerprint setting (TOFU mirror) */
static const struct setting tofu_trust_setting = {
	.name = "trust",
	.description = "Trusted server certificate fingerprint (TOFU)",
	.tag = DHCP_EB_TRUST,
	.type = &setting_type_hexraw,
};

/**
 * Locate non-volatile options settings block
 *
 * @ret settings	Settings block, or NULL
 */
static struct settings * tofu_settings ( void ) {
	return find_settings ( NVO_SETTINGS_NAME );
}

/**
 * Check whether a TOFU fingerprint is already stored
 *
 * @ret present		Fingerprint is present
 */
int tofu_fingerprint_present ( void ) {
	return setting_exists ( NULL, &server_fingerprint_setting );
}

/**
 * Store server leaf certificate fingerprint (TOFU)
 *
 * @v cert		Server certificate
 * @ret rc		Return status code
 */
int tofu_store ( struct x509_certificate *cert ) {
	struct settings *settings;
	uint8_t fingerprint[TOFU_FINGERPRINT_LEN];
	int rc;

	/* Sanity check */
	if ( ! cert )
		return -EINVAL;

	/* Calculate leaf certificate SHA-256 fingerprint */
	x509_fingerprint ( cert, &sha256_algorithm, fingerprint );

	/* Locate non-volatile options block */
	settings = tofu_settings();
	if ( ! settings )
		return -ENODEV;

	/* Store fingerprint as server fingerprint and trusted root */
	if ( ( rc = store_setting ( settings, &server_fingerprint_setting,
				    fingerprint, sizeof ( fingerprint ) ) ) != 0 )
		return rc;
	if ( ( rc = store_setting ( settings, &tofu_trust_setting,
				    fingerprint, sizeof ( fingerprint ) ) ) != 0 )
		return rc;

	return 0;
}
