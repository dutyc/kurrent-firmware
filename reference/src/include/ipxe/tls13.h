#ifndef _IPXE_TLS13_H
#define _IPXE_TLS13_H

/** @file
 *
 * TLS 1.3 pre-shared key connection
 *
 */

FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL );
FILE_SECBOOT ( PERMITTED );

#include <stdint.h>
#include <stddef.h>
#include <ipxe/socket.h>
#include <ipxe/interface.h>

extern int add_tls13_psk ( struct interface *xfer, const void *psk,
			   size_t psk_len, const char *identity,
			   struct sockaddr *peer, const char *name );

/** Socket opener used to create a connection
 *
 * Assignment is reserved for the self-tests, which substitute a mock
 * socket so that the connection layer can be driven without a network
 * stack.
 */
extern int ( * tls13_psk_open_socket ) ( struct interface *xfer, int semantics,
					 struct sockaddr *peer,
					 const char *name,
					 struct sockaddr *local );

#endif /* _IPXE_TLS13_H */
