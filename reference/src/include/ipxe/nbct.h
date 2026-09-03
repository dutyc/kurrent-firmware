#ifndef _IPXE_NBCT_H
#define _IPXE_NBCT_H

/** @file
 *
 * NVMe boot credentials table (NBCT)
 *
 * Session-scoped NVMe-oF credentials (DH-HMAC-CHAP secret, host NQN)
 * written by the firmware into a custom ACPI table for handoff to the
 * kernel/initramfs, avoiding a second network fetch of credentials.
 */

#include <ipxe/acpi.h>

/** NBCT ACPI table model */
extern struct acpi_model nbct_model __acpi_model;

#endif /* _IPXE_NBCT_H */
