#ifndef _IPXE_SBENROLL_DATA_H
#define _IPXE_SBENROLL_DATA_H

/** @file
 *
 * Secure Boot enrollment descriptors
 *
 * build/build-sb.sh replaces this stub with a generated header that
 * carries the signed PK/KEK/db descriptors.  Plain (non-Secure Boot)
 * builds keep the stub, so "sbenroll" reports "failed" without ever
 * touching the firmware variables.
 */

/** No enrollment descriptors are embedded */
#define SBENROLL_ENROLL_DATA 0

#endif /* _IPXE_SBENROLL_DATA_H */
