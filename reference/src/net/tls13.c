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
FILE_SECBOOT ( PERMITTED );

/** @file
 *
 * TLS 1.3 pre-shared key connection
 *
 * This is a minimal TLS 1.3 client for a single, external pre-shared
 * key: there are no certificates and no session resumption.  It is
 * inserted as a filter interface between a byte stream consumer (e.g.
 * the NVMe/TCP driver) and the underlying socket, in the same way as
 * the TLS 1.2 implementation in tls.c.
 *
 * The initial ClientHello (and the ServerHello) are sent and received
 * as plaintext handshake records; every subsequent record is protected
 * with AES-128-GCM using keys derived from the pre-shared key and an
 * ephemeral X25519 key exchange (RFC 8446 psk_dhe_ke).
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ipxe/malloc.h>
#include <ipxe/refcnt.h>
#include <ipxe/interface.h>
#include <ipxe/iobuf.h>
#include <ipxe/xfer.h>
#include <ipxe/open.h>
#include <ipxe/crypto.h>
#include <ipxe/aes.h>
#include <ipxe/sha256.h>
#include <ipxe/rbg.h>
#include <ipxe/tls.h>
#include <ipxe/tls13.h>

/* Identify errors as coming from this file */
#undef ERRFILE
#define ERRFILE ERRFILE_tls13

/** AES-128-GCM key length */
#define TLS13_KEY_LEN 16

/** Socket opener used to create a connection
 *
 * This is a function pointer so that the connection layer can be
 * exercised by the self-tests with a mock socket, without requiring a
 * network stack.  Production code never reassigns it.
 */
int ( * tls13_psk_open_socket ) ( struct interface *xfer, int semantics,
				  struct sockaddr *peer, const char *name,
				  struct sockaddr *local ) =
	xfer_open_named_socket;

/** Maximum size of a ClientHello handshake message */
#define TLS13_MAX_CLIENT_HELLO 512

/** Maximum plaintext record length accepted from the peer */
#define TLS13_MAX_PLAINTEXT 8192

/** Maximum ciphertext record length */
#define TLS13_MAX_RECORD ( 5 + TLS13_MAX_PLAINTEXT + 1 + 16 )

/** A TLS 1.3 record header */
struct tls13_psk_header {
	/** Content type */
	uint8_t type;
	/** Legacy record version */
	uint8_t version[2];
	/** Length of the following data */
	uint8_t length[2];
} __attribute__ (( packed ));

/** TLS 1.3 PSK connection phases */
enum tls13_psk_phase {
	/** Need to send the ClientHello */
	TLS13_PSK_CLIENT_HELLO = 0,
	/** Awaiting the server flight (ServerHello, EncryptedExtensions, Finished) */
	TLS13_PSK_SERVER_FLIGHT,
	/** Need to send the client Finished */
	TLS13_PSK_CLIENT_FINISHED,
	/** Handshake complete */
	TLS13_PSK_DATA,
	/** Failed */
	TLS13_PSK_FAILED,
};

/** Key direction */
enum tls13_psk_direction {
	/** Receive direction */
	TLS13_PSK_RX = 0,
	/** Transmit direction */
	TLS13_PSK_TX,
};

/** A TLS 1.3 pre-shared key connection */
struct tls13_psk {
	/** Reference count */
	struct refcnt refcnt;
	/** Plaintext stream interface */
	struct interface plainstream;
	/** Ciphertext stream interface */
	struct interface cipherstream;

	/** Digest algorithm */
	struct digest_algorithm *digest;
	/** Pre-shared key */
	void *psk;
	/** Length of pre-shared key */
	size_t psk_len;
	/** PSK identity */
	char *identity;
	/** Length of PSK identity */
	size_t identity_len;

	/** Handshake context */
	struct tls13_handshake hs;
	/** Connection phase */
	unsigned int phase;

	/** Client handshake traffic secret */
	uint8_t client_hs[32];
	/** Server handshake traffic secret */
	uint8_t server_hs[32];
	/** Client application traffic secret */
	uint8_t client_ap[32];
	/** Server application traffic secret */
	uint8_t server_ap[32];

	/** Transmit key */
	uint8_t tx_key[TLS13_KEY_LEN];
	/** Transmit nonce */
	uint8_t tx_iv[TLS13_NONCE_LEN];
	/** Receive key */
	uint8_t rx_key[TLS13_KEY_LEN];
	/** Receive nonce */
	uint8_t rx_iv[TLS13_NONCE_LEN];
	/** Transmit sequence number */
	uint64_t tx_seq;
	/** Receive sequence number */
	uint64_t rx_seq;

	/** Pending record to transmit */
	struct io_buffer *tx_iobuf;

	/** Receive buffer */
	uint8_t rx[TLS13_MAX_RECORD];
	/** Length of received data */
	size_t rx_len;
};

/**
 * Derive a traffic key in the given direction
 *
 * @v tls		TLS connection
 * @v direction		Key direction
 * @v secret		Traffic secret
 */
static void tls13_psk_set_key ( struct tls13_psk *tls,
				enum tls13_psk_direction direction,
				const void *secret ) {
	uint8_t *key = ( direction ? tls->tx_key : tls->rx_key );
	uint8_t *iv = ( direction ? tls->tx_iv : tls->rx_iv );

	tls13_traffic_key ( tls->digest, secret, key, TLS13_KEY_LEN,
			    iv, TLS13_NONCE_LEN );
}

/**
 * Construct an encrypted record
 *
 * @v tls		TLS connection
 * @v type		Inner content type
 * @v data		Plaintext data
 * @v len		Length of plaintext data
 * @ret iobuf		I/O buffer, or NULL on failure
 */
static struct io_buffer * tls13_psk_cipher_record ( struct tls13_psk *tls,
						    unsigned int type,
						    const void *data,
						    size_t len ) {
	struct cipher_algorithm *cipher = &aes_gcm_algorithm;
	size_t cipher_len = ( len + 1 + cipher->authsize );
	struct tls13_psk_header *header;
	struct io_buffer *iobuf;
	size_t out_len;

	iobuf = alloc_iob ( sizeof ( *header ) + cipher_len );
	if ( ! iobuf )
		return NULL;
	header = iob_put ( iobuf, sizeof ( *header ) );
	header->type = TLS_TYPE_DATA;
	header->version[0] = ( TLS_VERSION_TLS_1_2 >> 8 );
	header->version[1] = ( TLS_VERSION_TLS_1_2 & 0xff );
	header->length[0] = ( cipher_len >> 8 );
	header->length[1] = ( cipher_len & 0xff );

	out_len = tls13_seal ( cipher, tls->tx_key, TLS13_KEY_LEN, tls->tx_iv,
			       tls->tx_seq, header, sizeof ( *header ), data,
			       len, type, iob_put ( iobuf, cipher_len ) );
	if ( out_len != cipher_len ) {
		free_iob ( iobuf );
		return NULL;
	}
	tls->tx_seq++;
	return iobuf;
}

/**
 * Construct the ClientHello record
 *
 * @v tls		TLS connection
 * @ret iobuf		I/O buffer, or NULL on failure
 */
static struct io_buffer * tls13_psk_client_hello ( struct tls13_psk *tls ) {
	struct tls13_psk_header *header;
	struct io_buffer *iobuf;
	uint8_t random[32];
	uint8_t *ch;
	size_t len;
	int rc;

	/* Generate client random */
	if ( ( rc = rbg_generate ( NULL, 0, 0, random, sizeof ( random ) ) ) != 0 )
		return NULL;

	/* Allocate buffer for the record header and ClientHello */
	iobuf = alloc_iob ( sizeof ( *header ) + TLS13_MAX_CLIENT_HELLO );
	if ( ! iobuf )
		return NULL;
	header = iob_put ( iobuf, sizeof ( *header ) );
	ch = iob_put ( iobuf, TLS13_MAX_CLIENT_HELLO );

	/* Construct ClientHello */
	len = tls13_client_hello ( ch, TLS13_MAX_CLIENT_HELLO, random,
				   tls->hs.key.public_key, tls->psk,
				   tls->psk_len, tls->identity,
				   tls->identity_len, tls->hs.binder_label );
	if ( ! len ) {
		free_iob ( iobuf );
		return NULL;
	}
	iob_unput ( iobuf, ( TLS13_MAX_CLIENT_HELLO - len ) );

	/* Construct record header */
	header->type = TLS_TYPE_HANDSHAKE;
	header->version[0] = ( TLS_VERSION_TLS_1_2 >> 8 );
	header->version[1] = ( TLS_VERSION_TLS_1_2 & 0xff );
	header->length[0] = ( len >> 8 );
	header->length[1] = ( len & 0xff );

	/* Append to the handshake transcript */
	if ( tls13_handshake_update ( &tls->hs, ch, len ) != 0 ) {
		free_iob ( iobuf );
		return NULL;
	}

	return iobuf;
}

/**
 * Fail the connection
 *
 * @v tls		TLS connection
 * @v rc		Reason for failure
 */
static void tls13_psk_fail ( struct tls13_psk *tls, int rc ) {

	if ( tls->phase == TLS13_PSK_FAILED )
		return;
	DBGC ( tls, "TLS13 %p failed: %s\n", tls, strerror ( rc ) );
	tls->phase = TLS13_PSK_FAILED;
	intf_shutdown ( &tls->plainstream, rc );
	intf_shutdown ( &tls->cipherstream, rc );
}

/**
 * Transmit any pending record
 *
 * @v tls		TLS connection
 */
static void tls13_psk_tx ( struct tls13_psk *tls ) {
	uint8_t verify[32];
	uint8_t finished[4 + 32];

	/* Refuse to run if the connection has failed */
	if ( tls->phase == TLS13_PSK_FAILED )
		return;

	/* Construct the next handshake record, if applicable */
	if ( ! tls->tx_iobuf ) {
		switch ( tls->phase ) {
		case TLS13_PSK_CLIENT_HELLO:
			tls->tx_iobuf = tls13_psk_client_hello ( tls );
			if ( ! tls->tx_iobuf ) {
				tls13_psk_fail ( tls, -EINVAL );
				return;
			}
			tls->phase = TLS13_PSK_SERVER_FLIGHT;
			DBGC ( tls, "TLS13 %p sending ClientHello\n", tls );
			break;
		case TLS13_PSK_CLIENT_FINISHED:
			tls13_handshake_finished ( &tls->hs, tls->client_hs,
						   verify );
			finished[0] = TLS_FINISHED;
			finished[1] = 0;
			finished[2] = 0;
			finished[3] = sizeof ( verify );
			memcpy ( &finished[4], verify, sizeof ( verify ) );
			tls->tx_iobuf = tls13_psk_cipher_record ( tls,
								  TLS_TYPE_HANDSHAKE,
								  finished,
								  sizeof ( finished ) );
			if ( ! tls->tx_iobuf ) {
				tls13_psk_fail ( tls, -EINVAL );
				return;
			}
			DBGC ( tls, "TLS13 %p sending client Finished\n", tls );
			break;
		default:
			/* Nothing to transmit */
			break;
		}
	}

	/* Transmit any pending record, if the socket window allows */
	if ( tls->tx_iobuf && ( xfer_window ( &tls->cipherstream ) != 0 ) ) {
		xfer_deliver_iob ( &tls->cipherstream,
				   iob_disown ( tls->tx_iobuf ) );

		/* Completing the ClientFinished switches to the
		 * application traffic key.
		 */
		if ( tls->phase == TLS13_PSK_CLIENT_FINISHED ) {
			tls13_psk_set_key ( tls, TLS13_PSK_TX, tls->client_ap );
			tls->tx_seq = 0;
			tls->phase = TLS13_PSK_DATA;
			DBGC ( tls, "TLS13 %p handshake complete\n", tls );
		}
	}

	/* The ciphertext window may have changed, and the plaintext
	 * window is derived from it (see tls13_psk_plainstream_window()).
	 * This function is the ciphertext window callback and also runs
	 * after every record transmission, so notify the plaintext
	 * stream unconditionally: iPXE's TCP layer reports a zero window
	 * while a segment remains unacknowledged, and a missed
	 * notification would stall the consumer indefinitely.
	 */
	xfer_window_changed ( &tls->plainstream );
}

/**
 * Handle a ServerHello handshake message
 *
 * @v tls		TLS connection
 * @v msg		Handshake message
 * @v len		Length of handshake message
 * @ret rc		Return status code
 */
static int tls13_psk_server_hello ( struct tls13_psk *tls, const void *msg,
				    size_t len ) {
	struct tls13_server_hello hello;
	int rc;

	/* Parse and validate the ServerHello */
	if ( ( rc = tls13_parse_server_hello ( msg, len, &hello ) ) != 0 )
		return rc;
	if ( hello.version != TLS_VERSION_TLS_1_3 )
		return -EINVAL;
	if ( hello.cipher_suite != TLS_AES_128_GCM_SHA256 )
		return -EINVAL;
	if ( ! hello.has_key_share )
		return -EINVAL;
	if ( ! hello.has_psk )
		return -EINVAL;

	/* Append to the transcript, then perform the key exchange */
	if ( ( rc = tls13_handshake_update ( &tls->hs, msg, len ) ) != 0 )
		return rc;
	if ( ( rc = tls13_handshake_exchange ( &tls->hs,
					       hello.public_key ) ) != 0 )
		return rc;

	/* Derive the handshake traffic secrets and keys */
	tls13_handshake_derive ( &tls->hs, tls->hs.handshake, "c hs traffic",
				 tls->client_hs );
	tls13_handshake_derive ( &tls->hs, tls->hs.handshake, "s hs traffic",
				 tls->server_hs );
	tls13_psk_set_key ( tls, TLS13_PSK_TX, tls->client_hs );
	tls13_psk_set_key ( tls, TLS13_PSK_RX, tls->server_hs );
	tls->tx_seq = 0;
	tls->rx_seq = 0;

	DBGC ( tls, "TLS13 %p received ServerHello\n", tls );
	return 0;
}

/**
 * Handle a server Finished handshake message
 *
 * @v tls		TLS connection
 * @v msg		Handshake message
 * @v len		Length of handshake message
 * @ret rc		Return status code
 */
static int tls13_psk_server_finished ( struct tls13_psk *tls, const void *msg,
				       size_t len ) {
	uint8_t verify[32];
	int rc;

	/* Verify the Finished message against the transcript so far */
	if ( len != ( 4 + sizeof ( verify ) ) )
		return -EINVAL;
	tls13_handshake_finished ( &tls->hs, tls->server_hs, verify );
	if ( memcmp ( verify, ( ( const uint8_t * ) msg + 4 ),
		      sizeof ( verify ) ) != 0 ) {
		DBGC ( tls, "TLS13 %p server Finished mismatch\n", tls );
		return -EINVAL;
	}

	/* Append the server Finished to the transcript */
	if ( ( rc = tls13_handshake_update ( &tls->hs, msg, len ) ) != 0 )
		return rc;

	/* Derive the Master Secret and application traffic secrets */
	tls13_handshake_master ( &tls->hs );
	tls13_handshake_derive ( &tls->hs, tls->hs.master, "c ap traffic",
				 tls->client_ap );
	tls13_handshake_derive ( &tls->hs, tls->hs.master, "s ap traffic",
				 tls->server_ap );

	/* The server now protects records with its application key */
	tls13_psk_set_key ( tls, TLS13_PSK_RX, tls->server_ap );
	tls->rx_seq = 0;

	/* The client must now send its own Finished */
	tls->phase = TLS13_PSK_CLIENT_FINISHED;

	DBGC ( tls, "TLS13 %p received server Finished\n", tls );
	return 0;
}

/**
 * Handle handshake messages
 *
 * @v tls		TLS connection
 * @v data		Handshake messages
 * @v len		Length of handshake messages
 * @ret rc		Return status code
 */
static int tls13_psk_handshake ( struct tls13_psk *tls, const void *data,
				 size_t len ) {
	const uint8_t *msg = data;
	size_t remaining = len;
	unsigned int type;
	size_t msg_len;
	size_t total;
	int rc;

	while ( remaining >= 4 ) {
		type = msg[0];
		msg_len = ( ( ( size_t ) msg[1] << 16 ) | ( ( size_t ) msg[2] << 8 )
			    | msg[3] );
		total = ( 4 + msg_len );
		if ( total > remaining ) {
			DBGC ( tls, "TLS13 %p fragmentated handshake message\n",
			       tls );
			return -EINVAL;
		}

		switch ( type ) {

		case TLS_SERVER_HELLO:
			if ( ( rc = tls13_psk_server_hello ( tls, msg,
							     total ) ) != 0 )
				return rc;
			break;

		case TLS_ENCRYPTED_EXTENSIONS:
			if ( ( rc = tls13_handshake_update ( &tls->hs, msg,
							     total ) ) != 0 )
				return rc;
			break;

		case TLS_FINISHED:
			if ( ( rc = tls13_psk_server_finished ( tls, msg,
								total ) ) != 0 )
				return rc;
			break;

		case TLS_NEW_SESSION_TICKET:
			/* Post-handshake message; ignored (no resumption) */
			break;

		default:
			DBGC ( tls, "TLS13 %p unexpected handshake type %d\n",
			       tls, type );
			return -EINVAL;
		}

		msg += total;
		remaining -= total;
	}

	return 0;
}

/**
 * Deliver decrypted data to the plaintext stream
 *
 * @v tls		TLS connection
 * @v data		Plaintext data
 * @v len		Length of plaintext data
 * @ret rc		Return status code
 */
static int tls13_psk_deliver ( struct tls13_psk *tls, const void *data,
			       size_t len ) {
	struct io_buffer *iobuf;

	if ( ! len )
		return 0;
	iobuf = alloc_iob ( len );
	if ( ! iobuf )
		return -ENOMEM;
	memcpy ( iob_put ( iobuf, len ), data, len );
	return xfer_deliver_iob ( &tls->plainstream, iobuf );
}

/**
 * Handle a received record
 *
 * @v tls		TLS connection
 * @v record		Record (including header)
 * @v total		Total length of record
 * @ret rc		Return status code
 */
static int tls13_psk_record ( struct tls13_psk *tls, uint8_t *record,
			      size_t total ) {
	unsigned int type = record[0];
	size_t record_len = ( total - 5 );
	size_t plain_len;
	int content_type;

	/* Compatibility ChangeCipherSpec records are ignored */
	if ( type == TLS_TYPE_CHANGE_CIPHER )
		return 0;

	/* The ServerHello is sent as a plaintext handshake record */
	if ( type == TLS_TYPE_HANDSHAKE )
		return tls13_psk_handshake ( tls, &record[5], record_len );

	if ( type != TLS_TYPE_DATA ) {
		DBGC ( tls, "TLS13 %p unexpected record type %d\n", tls, type );
		return -EINVAL;
	}

	/* Decrypt the record in place */
	content_type = tls13_open ( &aes_gcm_algorithm, tls->rx_key,
				    TLS13_KEY_LEN, tls->rx_iv, tls->rx_seq,
				    record, 5, &record[5], record_len,
				    &record[5], &plain_len );
	if ( content_type < 0 ) {
		DBGC ( tls, "TLS13 %p could not decrypt record\n", tls );
		return -EINVAL;
	}
	tls->rx_seq++;

	switch ( content_type ) {

	case TLS_TYPE_HANDSHAKE:
		return tls13_psk_handshake ( tls, &record[5], plain_len );

	case TLS_TYPE_DATA:
		return tls13_psk_deliver ( tls, &record[5], plain_len );

	case TLS_TYPE_ALERT:
		DBGC ( tls, "TLS13 %p received alert %d\n", tls,
		       ( plain_len ? record[5] : -1 ) );
		return -EINVAL;

	default:
		DBGC ( tls, "TLS13 %p unexpected inner type %d\n", tls,
		       content_type );
		return -EINVAL;
	}
}

/**
 * Process received records
 *
 * @v tls		TLS connection
 */
static void tls13_psk_rx ( struct tls13_psk *tls ) {
	size_t record_len;
	size_t total;
	int rc;

	while ( tls->rx_len >= 5 ) {

		record_len = ( ( ( size_t ) tls->rx[3] << 8 ) | tls->rx[4] );
		total = ( 5 + record_len );
		if ( total > sizeof ( tls->rx ) ) {
			tls13_psk_fail ( tls, -EINVAL );
			return;
		}
		if ( tls->rx_len < total )
			break;

		if ( ( rc = tls13_psk_record ( tls, tls->rx, total ) ) != 0 ) {
			tls13_psk_fail ( tls, rc );
			return;
		}

		memmove ( tls->rx, &tls->rx[total], ( tls->rx_len - total ) );
		tls->rx_len -= total;

		/* Any record received during the handshake may have
		 * completed the handshake and thus unblocked transmission.
		 */
		tls13_psk_tx ( tls );
	}
}

/**
 * Handle received ciphertext
 *
 * @v tls		TLS connection
 * @v iobuf		I/O buffer
 * @v meta		Data transfer metadata
 * @ret rc		Return status code
 */
static int tls13_psk_cipherstream_deliver ( struct tls13_psk *tls,
					    struct io_buffer *iobuf,
					    struct xfer_metadata *meta __unused ) {
	size_t len = iob_len ( iobuf );

	if ( ( tls->rx_len + len ) > sizeof ( tls->rx ) ) {
		free_iob ( iobuf );
		tls13_psk_fail ( tls, -EINVAL );
		return -EINVAL;
	}
	memcpy ( &tls->rx[tls->rx_len], iobuf->data, len );
	tls->rx_len += len;
	free_iob ( iobuf );

	tls13_psk_rx ( tls );
	return 0;
}

/**
 * Handle window change on the ciphertext stream
 *
 * @v tls		TLS connection
 */
static void tls13_psk_cipherstream_window ( struct tls13_psk *tls ) {

	tls13_psk_tx ( tls );
}

/**
 * Get plaintext stream window
 *
 * @v tls		TLS connection
 * @ret len		Length of window
 */
static size_t tls13_psk_plainstream_window ( struct tls13_psk *tls ) {

	/* Block transmission until the handshake is complete and any
	 * previously delivered record has been transmitted.
	 */
	if ( tls->phase != TLS13_PSK_DATA )
		return 0;
	if ( tls->tx_iobuf )
		return 0;
	return xfer_window ( &tls->cipherstream );
}

/**
 * Handle delivery of plaintext data
 *
 * @v tls		TLS connection
 * @v iobuf		I/O buffer
 * @v meta		Data transfer metadata
 * @ret rc		Return status code
 */
static int tls13_psk_plainstream_deliver ( struct tls13_psk *tls,
					   struct io_buffer *iobuf,
					   struct xfer_metadata *meta __unused ) {
	struct io_buffer *record;

	/* Sanity check */
	if ( tls->phase != TLS13_PSK_DATA ) {
		free_iob ( iobuf );
		return -EINVAL;
	}

	/* Encrypt into a record and transmit */
	record = tls13_psk_cipher_record ( tls, TLS_TYPE_DATA, iobuf->data,
					   iob_len ( iobuf ) );
	free_iob ( iobuf );
	if ( ! record )
		return -ENOMEM;
	tls->tx_iobuf = record;
	tls13_psk_tx ( tls );
	return 0;
}

/**
 * Close the connection
 *
 * @v tls		TLS connection
 * @v rc		Reason for close
 */
static void tls13_psk_close ( struct tls13_psk *tls, int rc ) {

	tls->phase = TLS13_PSK_FAILED;
	intf_shutdown ( &tls->plainstream, rc );
	intf_shutdown ( &tls->cipherstream, rc );
}

/** TLS 1.3 PSK plaintext stream interface operations */
static struct interface_operation tls13_psk_plainstream_ops[] = {
	INTF_OP ( xfer_deliver, struct tls13_psk *,
		  tls13_psk_plainstream_deliver ),
	INTF_OP ( xfer_window, struct tls13_psk *, tls13_psk_plainstream_window ),
	INTF_OP ( intf_close, struct tls13_psk *, tls13_psk_close ),
};

/** TLS 1.3 PSK plaintext stream interface descriptor */
static struct interface_descriptor tls13_psk_plainstream_desc =
	INTF_DESC ( struct tls13_psk, plainstream, tls13_psk_plainstream_ops );

/** TLS 1.3 PSK ciphertext stream interface operations */
static struct interface_operation tls13_psk_cipherstream_ops[] = {
	INTF_OP ( xfer_deliver, struct tls13_psk *,
		  tls13_psk_cipherstream_deliver ),
	INTF_OP ( xfer_window_changed, struct tls13_psk *,
		  tls13_psk_cipherstream_window ),
	INTF_OP ( intf_close, struct tls13_psk *, tls13_psk_close ),
};

/** TLS 1.3 PSK ciphertext stream interface descriptor */
static struct interface_descriptor tls13_psk_cipherstream_desc =
	INTF_DESC ( struct tls13_psk, cipherstream, tls13_psk_cipherstream_ops );

/**
 * Free TLS 1.3 PSK connection
 *
 * @v refcnt		Reference count
 */
static void tls13_psk_free ( struct refcnt *refcnt ) {
	struct tls13_psk *tls =
		container_of ( refcnt, struct tls13_psk, refcnt );

	if ( tls->tx_iobuf )
		free_iob ( tls->tx_iobuf );
	free ( tls->psk );
	free ( tls->identity );
	free ( tls );
}

/**
 * Create a TLS 1.3 PSK connection
 *
 * @v xfer		Parent interface
 * @v psk		Pre-shared key
 * @v psk_len		Length of pre-shared key
 * @v identity		Pre-shared key identity (NUL-terminated)
 * @v peer		Peer socket address
 * @v name		Peer name (or NULL)
 * @ret rc		Return status code
 */
int add_tls13_psk ( struct interface *xfer, const void *psk, size_t psk_len,
		    const char *identity, struct sockaddr *peer,
		    const char *name ) {
	struct tls13_psk *tls;
	int rc;

	/* Allocate and initialise structure */
	tls = zalloc ( sizeof ( *tls ) );
	if ( ! tls ) {
		rc = -ENOMEM;
		goto err_alloc;
	}
	ref_init ( &tls->refcnt, tls13_psk_free );
	intf_init ( &tls->plainstream, &tls13_psk_plainstream_desc,
		    &tls->refcnt );
	intf_init ( &tls->cipherstream, &tls13_psk_cipherstream_desc,
		    &tls->refcnt );
	tls->digest = &sha256_algorithm;

	/* Record pre-shared key and identity */
	tls->psk = malloc ( psk_len );
	if ( ! tls->psk ) {
		rc = -ENOMEM;
		goto err_psk;
	}
	memcpy ( tls->psk, psk, psk_len );
	tls->psk_len = psk_len;
	tls->identity = strdup ( identity );
	if ( ! tls->identity ) {
		rc = -ENOMEM;
		goto err_identity;
	}
	tls->identity_len = strlen ( tls->identity );

	/* Initialise handshake context and generate an ephemeral key */
	tls13_handshake_init ( &tls->hs, tls->digest, tls->psk, tls->psk_len,
			       "ext binder" );
	if ( ( rc = tls13_generate_key ( &tls->hs.key ) ) != 0 )
		goto err_key;
	tls->phase = TLS13_PSK_CLIENT_HELLO;

	/* Open the socket beneath us.  This is the only remaining
	 * fallible operation, so it must be performed before we attach
	 * to the parent interface: otherwise a failure would leave the
	 * parent plugged to an interface that is about to be freed.
	 */
	if ( ( rc = tls13_psk_open_socket ( &tls->cipherstream, SOCK_STREAM,
					    peer, name, NULL ) ) != 0 ) {
		DBGC ( tls, "TLS13 %p could not open socket: %s\n", tls,
		       strerror ( rc ) );
		goto err_open;
	}

	/* Attach to parent interface */
	intf_plug_plug ( xfer, &tls->plainstream );

	/* Begin the handshake, mortalise self, and return */
	tls13_psk_tx ( tls );
	ref_put ( &tls->refcnt );
	return 0;

 err_open:
 err_key:
 err_identity:
 err_psk:
	ref_put ( &tls->refcnt );
 err_alloc:
	return rc;
}
