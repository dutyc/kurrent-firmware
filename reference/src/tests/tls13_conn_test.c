/*
 * Copyright (C) 2026 LECREATE <lecreate@foxmail.com>.
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

/** @file
 *
 * TLS 1.3 pre-shared key connection self-tests
 *
 * The connection layer in net/tls13.c is exercised in-process: the
 * socket below it is a mock, installed via the tls13_psk_open_socket()
 * injection point, and the consumer above it is a mock, so the
 * handshake state machine, the record layer and the flow-control
 * contract can all be driven without a peer.
 *
 * The server side of the handshake is played by the test itself, using
 * the same primitives as the client.  The client is not a party to that
 * reconstruction: it verifies the server Finished against its own
 * transcript and decrypts the server records with keys that it derived
 * independently, so a mistake here shows up as a failed handshake
 * rather than as a silently passing test.  The primitives themselves
 * are separately checked against the RFC 8448 vectors in tls13_test.c.
 */

/* Forcibly enable assertions */
#undef NDEBUG

/* Identify errors as coming from this file */
#undef ERRFILE
#define ERRFILE ERRFILE_tls13_test

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <ipxe/interface.h>
#include <ipxe/iobuf.h>
#include <ipxe/refcnt.h>
#include <ipxe/xfer.h>
#include <ipxe/aes.h>
#include <ipxe/sha256.h>
#include <ipxe/tls.h>
#include <ipxe/tls13.h>
#include <ipxe/test.h>

/** Number of records recorded by the mock socket */
#define TLS13_CONN_MAX_RECORDS 8

/** Length of the pre-shared key used by these tests */
#define TLS13_CONN_PSK_LEN 32

/** PSK identity used by these tests */
#define TLS13_CONN_IDENTITY "NVMe0R01 nqn.2026-07.com.kurrent:test"

/** A mock socket */
struct tls13_mock_socket {
	/** Reference count */
	struct refcnt refcnt;
	/** Data transfer interface */
	struct interface xfer;
	/** Transmit window size */
	size_t window;
	/** Number of socket opens */
	unsigned int opens;
	/** Number of records delivered */
	unsigned int records;
	/** Content type of each delivered record */
	uint8_t type[TLS13_CONN_MAX_RECORDS];
	/** First record delivered (the ClientHello) */
	uint8_t first[512];
	/** Length of the first record */
	size_t first_len;
	/** Total length of all records delivered */
	size_t total;
	/** Close reason, or 0 if the socket was never closed */
	int close_rc;
};

/** A mock consumer */
struct tls13_mock_consumer {
	/** Reference count */
	struct refcnt refcnt;
	/** Data transfer interface */
	struct interface xfer;
	/** Number of window change notifications */
	unsigned int window_changes;
	/** Number of plaintext buffers delivered */
	unsigned int records;
	/** Total length of plaintext delivered */
	size_t total;
	/** Plaintext delivered */
	uint8_t data[512];
	/** Length of plaintext delivered */
	size_t len;
	/** Close reason, or 0 if the consumer was never closed */
	int close_rc;
};

/** Mock socket */
static struct tls13_mock_socket mock;

/** Mock consumer */
static struct tls13_mock_consumer consumer;

/**
 * Handle record delivery from the connection to the mock socket
 *
 * @v sock		Mock socket
 * @v iobuf		Record
 * @v meta		Data transfer metadata
 * @ret rc		Return status code
 */
static int mock_socket_deliver ( struct tls13_mock_socket *sock,
				 struct io_buffer *iobuf,
				 struct xfer_metadata *meta __unused ) {
	size_t len = iob_len ( iobuf );

	/* Record the content type of each record */
	if ( sock->records < TLS13_CONN_MAX_RECORDS )
		sock->type[sock->records] = ( ( uint8_t * ) iobuf->data )[0];

	/* Retain the first record, which is the ClientHello */
	if ( ( sock->records == 0 ) && ( len <= sizeof ( sock->first ) ) ) {
		memcpy ( sock->first, iobuf->data, len );
		sock->first_len = len;
	}

	sock->records++;
	sock->total += len;
	free_iob ( iobuf );
	return 0;
}

/**
 * Get mock socket window
 *
 * @v sock		Mock socket
 * @ret len		Length of window
 */
static size_t mock_socket_window ( struct tls13_mock_socket *sock ) {

	return sock->window;
}

/**
 * Handle mock socket close
 *
 * @v sock		Mock socket
 * @v rc		Reason for close
 */
static void mock_socket_close ( struct tls13_mock_socket *sock, int rc ) {

	sock->close_rc = rc;
}

/** Mock socket interface operations */
static struct interface_operation mock_socket_ops[] = {
	INTF_OP ( xfer_deliver, struct tls13_mock_socket *,
		  mock_socket_deliver ),
	INTF_OP ( xfer_window, struct tls13_mock_socket *, mock_socket_window ),
	INTF_OP ( intf_close, struct tls13_mock_socket *, mock_socket_close ),
};

/** Mock socket interface descriptor */
static struct interface_descriptor mock_socket_desc =
	INTF_DESC ( struct tls13_mock_socket, xfer, mock_socket_ops );

/**
 * Handle plaintext window change on the mock consumer
 *
 * @v cnsmr		Mock consumer
 */
static void mock_consumer_window_changed ( struct tls13_mock_consumer *cnsmr ) {

	cnsmr->window_changes++;
}

/**
 * Handle plaintext delivery to the mock consumer
 *
 * @v cnsmr		Mock consumer
 * @v iobuf		Plaintext
 * @v meta		Data transfer metadata
 * @ret rc		Return status code
 */
static int mock_consumer_deliver ( struct tls13_mock_consumer *cnsmr,
				   struct io_buffer *iobuf,
				   struct xfer_metadata *meta __unused ) {
	size_t len = iob_len ( iobuf );

	if ( ( cnsmr->len + len ) <= sizeof ( cnsmr->data ) ) {
		memcpy ( &cnsmr->data[cnsmr->len], iobuf->data, len );
		cnsmr->len += len;
	}
	cnsmr->records++;
	cnsmr->total += len;
	free_iob ( iobuf );
	return 0;
}

/**
 * Get mock consumer window
 *
 * @v cnsmr		Mock consumer
 * @ret len		Length of window
 */
static size_t mock_consumer_window ( struct tls13_mock_consumer *cnsmr
				     __unused ) {

	return 0xffff;
}

/**
 * Handle mock consumer close
 *
 * @v cnsmr		Mock consumer
 * @v rc		Reason for close
 */
static void mock_consumer_close ( struct tls13_mock_consumer *cnsmr, int rc ) {

	cnsmr->close_rc = ( rc ? rc : -1 );
}

/** Mock consumer interface operations */
static struct interface_operation mock_consumer_ops[] = {
	INTF_OP ( xfer_window_changed, struct tls13_mock_consumer *,
		  mock_consumer_window_changed ),
	INTF_OP ( xfer_deliver, struct tls13_mock_consumer *,
		  mock_consumer_deliver ),
	INTF_OP ( xfer_window, struct tls13_mock_consumer *,
		  mock_consumer_window ),
	INTF_OP ( intf_close, struct tls13_mock_consumer *, mock_consumer_close ),
};

/** Mock consumer interface descriptor */
static struct interface_descriptor mock_consumer_desc =
	INTF_DESC ( struct tls13_mock_consumer, xfer, mock_consumer_ops );

/**
 * Open a mock socket
 *
 * @v xfer		Data transfer interface
 * @v semantics		Communication semantics
 * @v peer		Peer socket address
 * @v name		Peer name
 * @v local		Local socket address
 * @ret rc		Return status code
 *
 * This is installed as tls13_psk_open_socket(), so that a connection
 * may be created without a network stack.  The mock is plugged into
 * the caller's interface exactly as a real socket would be.
 */
static int mock_socket_open ( struct interface *xfer, int semantics,
			      struct sockaddr *peer, const char *name,
			      struct sockaddr *local ) {

	( void ) semantics;
	( void ) peer;
	( void ) name;
	( void ) local;

	mock.opens++;
	intf_plug_plug ( &mock.xfer, xfer );
	return 0;
}

/**
 * Reset the mock socket and consumer
 */
static void tls13_conn_reset ( void ) {

	memset ( &mock, 0, sizeof ( mock ) );
	memset ( &consumer, 0, sizeof ( consumer ) );
	ref_init ( &mock.refcnt, NULL );
	intf_init ( &mock.xfer, &mock_socket_desc, &mock.refcnt );
	ref_init ( &consumer.refcnt, NULL );
	intf_init ( &consumer.xfer, &mock_consumer_desc, &consumer.refcnt );
	mock.window = 0x10000;
	tls13_psk_open_socket = mock_socket_open;
}

/**
 * Tear down the connection under test
 */
static void tls13_conn_done ( void ) {

	/* Shutting down the consumer propagates through the connection
	 * and frees it.
	 */
	if ( consumer.close_rc == 0 )
		intf_shutdown ( &consumer.xfer, 0 );
}

/**
 * Create a connection under test
 *
 * @ret rc		Return status code
 */
static int tls13_conn_create ( void ) {
	uint8_t psk[TLS13_CONN_PSK_LEN];

	memset ( psk, 0x5a, sizeof ( psk ) );
	return add_tls13_psk ( &consumer.xfer, psk, sizeof ( psk ),
			       TLS13_CONN_IDENTITY, NULL, "mock" );
}

/**
 * Locate the client key share within a captured ClientHello record
 *
 * @v record		ClientHello record (including record header)
 * @v len		Length of record
 * @v public_key	Buffer for the X25519 public key
 * @ret rc		Return status code
 */
static int tls13_conn_client_key_share ( const uint8_t *record, size_t len,
					 uint8_t *public_key ) {
	const uint8_t *msg;
	const uint8_t *ext;
	const uint8_t *end;
	size_t msg_len;
	size_t ext_len;
	size_t elen;
	unsigned int type;

	/* Sanity check the record and handshake headers */
	if ( len < 5 )
		return -EINVAL;
	if ( record[0] != TLS_TYPE_HANDSHAKE )
		return -EINVAL;
	msg_len = ( ( ( size_t ) record[3] << 8 ) | record[4] );
	if ( ( 5 + msg_len ) > len )
		return -EINVAL;
	msg = &record[5];
	if ( msg_len < ( 47 + 2 ) )
		return -EINVAL;
	if ( msg[0] != TLS_CLIENT_HELLO )
		return -EINVAL;

	/* Walk the extension block.  The fixed prefix of the
	 * ClientHello has already been validated by tls13_test.c, so
	 * only the extension block is re-parsed here.
	 */
	ext_len = ( ( ( size_t ) msg[45] << 8 ) | msg[46] );
	if ( ( 47 + ext_len ) > msg_len )
		return -EINVAL;
	ext = &msg[47];
	end = &msg[47 + ext_len];
	while ( ext < end ) {
		if ( ( ( size_t ) ( end - ext ) ) < 4 )
			return -EINVAL;
		type = ( ( ext[0] << 8 ) | ext[1] );
		elen = ( ( ext[2] << 8 ) | ext[3] );
		ext += 4;
		if ( ( ( size_t ) ( end - ext ) ) < elen )
			return -EINVAL;
		if ( type == TLS_KEY_SHARE ) {
			/* client_shares: u16 length, u16 group,
			 * u16 key length, 32-byte key
			 */
			if ( elen != ( 2 + 2 + 2 + 32 ) )
				return -EINVAL;
			if ( ( ( ext[2] << 8 ) | ext[3] ) !=
			     TLS_NAMED_GROUP_X25519 )
				return -EINVAL;
			if ( ( ( ext[4] << 8 ) | ext[5] ) != 32 )
				return -EINVAL;
			memcpy ( public_key, &ext[6], 32 );
			return 0;
		}
		ext += elen;
	}

	return -ENOENT;
}

/**
 * Construct the server flight (ServerHello, EncryptedExtensions, Finished)
 *
 * @v hs		Server handshake context (already keyed)
 * @v server_hello	Buffer for the ServerHello handshake message
 * @v server_hello_len	Length of ServerHello, or 0 on error
 * @v record		Buffer for the encrypted records
 * @v record_len	Length of records, or 0 on error
 *
 * @ret rc		Return status code
 */
static int tls13_conn_server_flight ( struct tls13_handshake *hs,
				      uint8_t *server_hello,
				      size_t *server_hello_len,
				      uint8_t *record, size_t *record_len ) {
	uint8_t c_hs[32];
	uint8_t s_hs[32];
	uint8_t key[16];
	uint8_t iv[TLS13_NONCE_LEN];
	uint8_t plain[ 4 + 4 + 32 ];
	uint8_t verify[32];
	uint8_t *sh = server_hello;
	uint8_t *out = &record[5];
	size_t ext_len_off;
	size_t ext_start;
	size_t ext_len;
	size_t msg_len;
	size_t cipher_len;
	size_t n = 0;
	size_t plain_len = 0;

	*server_hello_len = 0;
	*record_len = 0;

	/* ServerHello: header (length filled in later) */
	sh[n++] = TLS_SERVER_HELLO;
	sh[n++] = 0; sh[n++] = 0; sh[n++] = 0;

	/* legacy_version and random */
	sh[n++] = ( TLS_VERSION_TLS_1_2 >> 8 );
	sh[n++] = ( TLS_VERSION_TLS_1_2 & 0xff );
	memset ( &sh[n], 0x37, 32 ); n += 32;

	/* legacy_session_id_echo (empty), cipher_suite, compression */
	sh[n++] = 0;
	sh[n++] = ( TLS_AES_128_GCM_SHA256 >> 8 );
	sh[n++] = ( TLS_AES_128_GCM_SHA256 & 0xff );
	sh[n++] = 0;

	/* extensions (length filled in later) */
	ext_len_off = n;
	sh[n++] = 0; sh[n++] = 0;
	ext_start = n;

	/* supported_versions = { TLS 1.3 } */
	sh[n++] = 0x00; sh[n++] = TLS_SUPPORTED_VERSIONS;
	sh[n++] = 0x00; sh[n++] = 0x02;
	sh[n++] = ( TLS_VERSION_TLS_1_3 >> 8 );
	sh[n++] = ( TLS_VERSION_TLS_1_3 & 0xff );

	/* key_share = { x25519: hs->key.public_key } */
	sh[n++] = 0x00; sh[n++] = TLS_KEY_SHARE;
	sh[n++] = 0x00; sh[n++] = 0x24;
	sh[n++] = 0x00; sh[n++] = TLS_NAMED_GROUP_X25519;
	sh[n++] = 0x00; sh[n++] = 0x20;
	memcpy ( &sh[n], hs->key.public_key, 32 ); n += 32;

	/* pre_shared_key = { selected_identity = 0 } */
	sh[n++] = 0x00; sh[n++] = TLS_PRE_SHARED_KEY;
	sh[n++] = 0x00; sh[n++] = 0x02;
	sh[n++] = 0x00; sh[n++] = 0x00;

	/* Fill in the extension and message lengths */
	ext_len = ( n - ext_start );
	sh[ext_len_off] = ( ext_len >> 8 );
	sh[ext_len_off + 1] = ( ext_len & 0xff );
	msg_len = ( n - 4 );
	sh[1] = ( msg_len >> 16 );
	sh[2] = ( msg_len >> 8 );
	sh[3] = ( msg_len & 0xff );

	/* Append the ServerHello to the server transcript */
	if ( tls13_handshake_update ( hs, server_hello, n ) != 0 )
		return -EINVAL;
	*server_hello_len = n;

	/* Derive the handshake traffic secrets and the server key */
	tls13_handshake_derive ( hs, hs->handshake, "c hs traffic", c_hs );
	tls13_handshake_derive ( hs, hs->handshake, "s hs traffic", s_hs );
	tls13_traffic_key ( hs->digest, s_hs, key, sizeof ( key ),
			    iv, sizeof ( iv ) );

	/* EncryptedExtensions (empty) */
	plain[plain_len++] = TLS_ENCRYPTED_EXTENSIONS;
	plain[plain_len++] = 0; plain[plain_len++] = 0; plain[plain_len++] = 0;
	if ( tls13_handshake_update ( hs, plain, plain_len ) != 0 )
		return -EINVAL;

	/* Server Finished */
	tls13_handshake_finished ( hs, s_hs, verify );
	plain[plain_len++] = TLS_FINISHED;
	plain[plain_len++] = 0; plain[plain_len++] = 0;
	plain[plain_len++] = sizeof ( verify );
	memcpy ( &plain[plain_len], verify, sizeof ( verify ) );
	plain_len += sizeof ( verify );

	/* Encrypt the flight into a single protected record */
	cipher_len = ( plain_len + 1 + aes_gcm_algorithm.authsize );
	record[0] = TLS_TYPE_DATA;
	record[1] = ( TLS_VERSION_TLS_1_2 >> 8 );
	record[2] = ( TLS_VERSION_TLS_1_2 & 0xff );
	record[3] = ( cipher_len >> 8 );
	record[4] = ( cipher_len & 0xff );
	if ( tls13_seal ( &aes_gcm_algorithm, key, sizeof ( key ), iv, 0,
			  record, 5, plain, plain_len, TLS_TYPE_HANDSHAKE,
			  out ) != cipher_len )
		return -EINVAL;
	*record_len = ( 5 + cipher_len );

	return 0;
}

/**
 * Deliver a record to the connection under test
 *
 * @v data		Record
 * @v len		Length of record
 * @ret rc		Return status code
 */
static int tls13_conn_deliver ( const void *data, size_t len ) {
	struct io_buffer *iobuf;

	iobuf = alloc_iob ( len );
	if ( ! iobuf )
		return -ENOMEM;
	memcpy ( iob_put ( iobuf, len ), data, len );
	return xfer_deliver_iob ( &mock.xfer, iobuf );
}

/**
 * Deliver a handshake message to the connection under test
 *
 * @v msg		Handshake message
 * @v len		Length of handshake message
 * @ret rc		Return status code
 *
 * The message is sent as a plaintext handshake record, as a server
 * does for the ServerHello (and for the whole flight when no
 * encryption is in use).
 */
static int tls13_conn_deliver_handshake ( const void *msg, size_t len ) {
	uint8_t record[ 5 + 256 ];
	uint8_t *hdr = record;

	if ( len > 256 )
		return -EINVAL;
	hdr[0] = TLS_TYPE_HANDSHAKE;
	hdr[1] = ( TLS_VERSION_TLS_1_2 >> 8 );
	hdr[2] = ( TLS_VERSION_TLS_1_2 & 0xff );
	hdr[3] = ( len >> 8 );
	hdr[4] = ( len & 0xff );
	memcpy ( &record[5], msg, len );
	return tls13_conn_deliver ( record, ( 5 + len ) );
}

/**
 * Report a window-contract test for the connection layer
 *
 * The connection layer must notify the plaintext stream whenever the
 * ciphertext window may have changed, even when it has no record to
 * transmit at that moment.  A consumer that waits on the plaintext
 * window (as the NVMe/TCP driver does before issuing its first command)
 * would otherwise never be woken again.
 */
static void tls13_conn_window_test ( void ) {

	tls13_conn_reset();

	/* Establish the connection: the ClientHello is transmitted
	 * immediately, leaving no pending record and the plaintext
	 * window still closed because the handshake is incomplete.
	 */
	ok ( tls13_conn_create() == 0 );
	ok ( mock.opens == 1 );
	ok ( mock.records == 1 );
	ok ( mock.type[0] == TLS_TYPE_HANDSHAKE );
	ok ( xfer_window ( &consumer.xfer ) == 0 );

	/* The socket reports that its window has changed (e.g. an ACK
	 * has freed the transmit window).  There is nothing to send,
	 * but the plaintext stream must still be notified.
	 */
	consumer.window_changes = 0;
	xfer_window_changed ( &mock.xfer );
	ok ( consumer.window_changes == 1 );

	tls13_conn_done();
}

/**
 * Report a handshake and data-transfer test for the connection layer
 *
 * This drives a complete handshake against a server played by the
 * test, then transfers data in both directions, and finally exercises
 * the window contract in the established state.
 */
static void tls13_conn_handshake_test ( void ) {
	struct tls13_handshake hs;
	uint8_t client_key[32];
	uint8_t server_hello[128];
	uint8_t record[256];
	uint8_t psk[TLS13_CONN_PSK_LEN];
	struct io_buffer *iobuf;
	size_t server_hello_len;
	size_t record_len;
	size_t msg_len;

	tls13_conn_reset();
	memset ( psk, 0x5a, sizeof ( psk ) );

	/* Establish the connection and capture its ClientHello */
	ok ( tls13_conn_create() == 0 );
	ok ( mock.records == 1 );
	ok ( tls13_conn_client_key_share ( mock.first, mock.first_len,
					   client_key ) == 0 );
	msg_len = ( ( ( size_t ) mock.first[3] << 8 ) | mock.first[4] );

	/* Play the server: initialise a handshake context with the same
	 * pre-shared key, absorb the ClientHello, generate an ephemeral
	 * key and agree the shared secret.
	 *
	 * The binder label differs (the client sends no resumption
	 * ticket, so it uses the "ext binder" label) but the label only
	 * affects the binder calculation, not the early secret from
	 * which the handshake keys are derived.
	 */
	tls13_handshake_init ( &hs, &sha256_algorithm, psk, sizeof ( psk ),
			       "res binder" );
	ok ( tls13_handshake_update ( &hs, &mock.first[5], msg_len ) == 0 );
	ok ( tls13_generate_key ( &hs.key ) == 0 );
	ok ( tls13_handshake_exchange ( &hs, client_key ) == 0 );

	/* Construct and absorb the ServerHello */
	ok ( tls13_conn_server_flight ( &hs, server_hello, &server_hello_len,
					record, &record_len ) == 0 );
	ok ( server_hello_len > 0 );
	ok ( record_len > 0 );

	/* The client must parse and accept the ServerHello, then decrypt
	 * and verify the rest of the flight.
	 */
	ok ( tls13_conn_deliver_handshake ( server_hello, server_hello_len ) == 0 );
	ok ( tls13_conn_deliver ( record, record_len ) == 0 );

	/* The handshake must now be complete: the client Finished has
	 * been transmitted (as a protected record), the plaintext
	 * window is open, and the connection has not been closed.
	 */
	ok ( consumer.close_rc == 0 );
	ok ( mock.records == 2 );
	ok ( mock.type[0] == TLS_TYPE_HANDSHAKE );
	ok ( mock.type[1] == TLS_TYPE_DATA );
	ok ( xfer_window ( &consumer.xfer ) != 0 );

	/* Transmit plaintext: it must reach the socket as a protected
	 * record rather than as a handshake record.
	 */
	iobuf = alloc_iob ( 16 );
	ok ( iobuf != NULL );
	memcpy ( iob_put ( iobuf, 5 ), "hello", 5 );
	ok ( xfer_deliver_iob ( &consumer.xfer, iobuf ) == 0 );
	ok ( mock.records == 3 );
	ok ( mock.type[2] == TLS_TYPE_DATA );

	/* The window contract must hold in the established state too:
	 * with nothing pending, a window change on the socket must
	 * still be propagated to the plaintext stream.
	 */
	mock.window = 0;
	consumer.window_changes = 0;
	xfer_window_changed ( &mock.xfer );
	ok ( consumer.window_changes == 1 );

	tls13_conn_done();
}

/**
 * Report all TLS 1.3 connection self-tests
 */
static void tls13_conn_test_exec ( void ) {

	tls13_conn_window_test();
	tls13_conn_handshake_test();
}

/** TLS 1.3 connection self-test */
struct self_test tls13_conn_test __self_test = {
	.name = "tls13conn",
	.exec = tls13_conn_test_exec,
};
