/*
 * Copyright (C) 2026 kurrent-firmware contributors.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of the
 * License, or (at your option) any later version.
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
 * NVMe-over-TCP DH-HMAC-CHAP authentication, modelled on the Linux
 * kernel NVMe-over-Fabrics authentication implementation
 * (drivers/nvme/host/auth.c and drivers/nvme/common/auth.c, GPL-2.0).
 */

FILE_LICENCE ( GPL2_ONLY );

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <byteswap.h>
#include <ipxe/crc32.h>
#include <ipxe/base64.h>
#include <ipxe/random_nz.h>
#include <ipxe/sha256.h>
#include <ipxe/sha512.h>
#include <ipxe/hmac.h>
#include <ipxe/ffdhe.h>
#include <ipxe/nvmetcp.h>

/* Identify errors as coming from this file */
#undef ERRFILE
#define ERRFILE ERRFILE_nvmetcp_auth

/** Maximum length of returned authentication data */
#define NVMETCP_AUTH_RECV_LEN 4096

/**
 * Get digest algorithm for a hash identifier
 *
 * @v hash_id		Hash algorithm identifier
 * @ret digest		Digest algorithm, or NULL
 */
static struct digest_algorithm *
nvmetcp_auth_hash ( unsigned int hash_id ) {

	switch ( hash_id ) {
	case NVME_AUTH_HASH_SHA256:
		return &sha256_algorithm;
	case NVME_AUTH_HASH_SHA384:
		return &sha384_algorithm;
	case NVME_AUTH_HASH_SHA512:
		return &sha512_algorithm;
	default:
		return NULL;
	}
}

/**
 * Get key exchange algorithm for a DH group identifier
 *
 * @v dhgid		DH group identifier
 * @ret exchange	Key exchange algorithm, or NULL
 */
static struct exchange_algorithm *
nvmetcp_auth_exchange ( unsigned int dhgid ) {

	switch ( dhgid ) {
	case NVME_AUTH_DHGROUP_2048:
		return &ffdhe2048_algorithm;
	case NVME_AUTH_DHGROUP_3072:
		return &ffdhe3072_algorithm;
	case NVME_AUTH_DHGROUP_4096:
		return &ffdhe4096_algorithm;
	default:
		return NULL;
	}
}

/**
 * Allocate HMAC context
 *
 * @v digest		Digest algorithm
 * @ret ctx		HMAC context, or NULL
 */
static void * nvmetcp_auth_hmac_alloc ( struct digest_algorithm *digest ) {

	return malloc ( hmac_ctxsize ( digest ) );
}

/**
 * Calculate HMAC of a single data buffer
 *
 * @v digest		Digest algorithm
 * @v key		HMAC key
 * @v key_len		Length of HMAC key
 * @v data		Data
 * @v data_len		Length of data
 * @v out		HMAC output
 * @ret rc		Return status code
 */
static int nvmetcp_auth_hmac ( struct digest_algorithm *digest,
			       const void *key, size_t key_len,
			       const void *data, size_t data_len, void *out ) {
	void *ctx;

	ctx = nvmetcp_auth_hmac_alloc ( digest );
	if ( ! ctx )
		return -ENOMEM;
	hmac_init ( digest, ctx, key, key_len );
	hmac_update ( digest, ctx, data, data_len );
	hmac_final ( digest, ctx, out );
	free ( ctx );
	return 0;
}

/**
 * Parse authentication secret
 *
 * @v nvmetcp		NVMe/TCP session
 * @v hash_id		Hash algorithm identifier to fill in
 * @v key		Key to fill in
 * @v key_len		Length of key to fill in
 * @ret rc		Return status code
 *
 * The secret has the format "DHHC-1:XX:base64", where XX is the hash
 * algorithm identifier and the base64-encoded data is the key
 * followed by a CRC32 checksum, as used by nvmet.
 */
static int nvmetcp_auth_parse_secret ( struct nvmetcp_session *nvmetcp,
				       uint8_t *hash_id, uint8_t *key,
				       size_t *key_len ) {
	const char *p = nvmetcp->secret;
	unsigned int id = 0;
	uint32_t crc;
	uint32_t crc_expected;
	int len;

	/* Parse "DHHC-1:XX:" prefix */
	if ( strncmp ( p, "DHHC-1:", 7 ) != 0 ) {
		DBGC ( nvmetcp, "invalid secret format\n" );
		return -EINVAL;
	}
	p += 7;
	while ( ( *p >= '0' ) && ( *p <= '9' ) ) {
		id = ( id * 10 ) + ( *p - '0' );
		p++;
	}
	if ( ( *p != ':' ) || ( id == 0 ) ||
	     ( id > NVME_AUTH_HASH_SHA512 ) ) {
		DBGC ( nvmetcp, "invalid secret hash identifier\n" );
		return -EINVAL;
	}
	p++;

	/* Decode key */
	len = base64_decode ( p, key, NVME_AUTH_MAX_DIGEST_SIZE + 4 );
	if ( len < 0 ) {
		DBGC ( nvmetcp, "invalid secret encoding: %s\n",
		       strerror ( len ) );
		return len;
	}
	if ( ( len != 36 ) && ( len != 52 ) && ( len != 68 ) ) {
		DBGC ( nvmetcp, "invalid secret length %d\n", len );
		return -EINVAL;
	}

	/* Verify CRC32 (last four bytes, little-endian) */
	*key_len = ( len - 4 );
	memcpy ( &crc_expected, key + *key_len, sizeof ( crc_expected ) );
	crc = ~crc32_le ( 0xffffffff, key, *key_len );
	if ( le32_to_cpu ( crc_expected ) != crc ) {
		DBGC ( nvmetcp, "secret CRC mismatch\n" );
		return -EACCES;
	}

	*hash_id = id;
	return 0;
}

/**
 * Transform authentication secret into a key
 *
 * @v nvmetcp		NVMe/TCP session
 * @v digest		Digest algorithm
 * @v key		Secret key
 * @v key_len		Length of secret key
 * @v transformed	Transformed key to fill in
 * @ret rc		Return status code
 *
 * The transformed key is HMAC(key, NQNh || "NVMe-over-Fabrics"), per
 * the NVMe base specification (DH-HMAC-CHAP).
 */
static int nvmetcp_auth_transform_key ( struct nvmetcp_session *nvmetcp,
					struct digest_algorithm *digest,
					const uint8_t *key, size_t key_len,
					uint8_t *transformed ) {
	void *ctx;

	ctx = nvmetcp_auth_hmac_alloc ( digest );
	if ( ! ctx )
		return -ENOMEM;
	hmac_init ( digest, ctx, key, key_len );
	hmac_update ( digest, ctx, nvmetcp->host_nqn,
		      strlen ( nvmetcp->host_nqn ) );
	hmac_update ( digest, ctx, "NVMe-over-Fabrics", 17 );
	hmac_final ( digest, ctx, transformed );
	free ( ctx );
	return 0;
}

/**
 * Calculate host response value
 *
 * @v nvmetcp		NVMe/TCP session
 * @v digest		Digest algorithm
 * @v key		Transformed key
 * @v key_len		Length of transformed key
 * @v challenge		Challenge value
 * @v response		Response value to fill in
 * @ret rc		Return status code
 *
 * The response is HMAC(key, Ca || s1 || t_id || sc_c || "HostHost" ||
 * NQNh || 0x00 || NQNc), where Ca is the (possibly augmented)
 * challenge.
 */
static int nvmetcp_auth_response ( struct nvmetcp_session *nvmetcp,
				   struct digest_algorithm *digest,
				   const void *key, size_t key_len,
				   const void *challenge, void *response ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	void *ctx;
	uint32_t seqnum;
	uint16_t transaction;
	uint8_t sc_c;
	uint8_t nul = 0;

	ctx = nvmetcp_auth_hmac_alloc ( digest );
	if ( ! ctx )
		return -ENOMEM;
	hmac_init ( digest, ctx, key, key_len );
	hmac_update ( digest, ctx, challenge, auth->hl );
	seqnum = cpu_to_le32 ( auth->seqnum );
	hmac_update ( digest, ctx, &seqnum, sizeof ( seqnum ) );
	transaction = cpu_to_le16 ( auth->transaction );
	hmac_update ( digest, ctx, &transaction, sizeof ( transaction ) );
	sc_c = NVME_AUTH_SECP_NOSC;
	hmac_update ( digest, ctx, &sc_c, sizeof ( sc_c ) );
	hmac_update ( digest, ctx, "HostHost", 8 );
	hmac_update ( digest, ctx, nvmetcp->host_nqn,
		      strlen ( nvmetcp->host_nqn ) );
	hmac_update ( digest, ctx, &nul, sizeof ( nul ) );
	hmac_update ( digest, ctx, nvmetcp->subsystem_nqn,
		      strlen ( nvmetcp->subsystem_nqn ) );
	hmac_final ( digest, ctx, response );
	free ( ctx );
	return 0;
}

/**
 * Generate DH private key, public key and session key
 *
 * @v nvmetcp		NVMe/TCP session
 * @v exchange		Key exchange algorithm
 * @v digest		Digest algorithm
 * @v ctrl_key		Controller public key
 * @v ctrl_key_len	Length of controller public key
 * @ret rc		Return status code
 *
 * The session key is H(g^xy mod p), truncated to the digest size.
 */
static int nvmetcp_auth_dh_key ( struct nvmetcp_session *nvmetcp,
				 struct exchange_algorithm *exchange,
				 struct digest_algorithm *digest,
				 const uint8_t *ctrl_key ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	uint8_t shared[NVME_AUTH_MAX_DH_SIZE];
	void *ctx;
	int rc;

	/* Generate private key */
	if ( ( rc = get_random_nz ( auth->priv_key,
				    exchange->privsize ) ) != 0 )
		return rc;

	/* Generate public key */
	if ( ( rc = exchange->share ( exchange, auth->priv_key,
				      auth->pub_key ) ) != 0 ) {
		DBGC ( nvmetcp, "could not generate DH public key: %s\n",
		       strerror ( rc ) );
		return rc;
	}

	/* Calculate shared secret */
	if ( ( rc = exchange->agree ( exchange, auth->priv_key, ctrl_key,
				      shared ) ) != 0 ) {
		DBGC ( nvmetcp, "could not calculate DH shared secret: %s\n",
		       strerror ( rc ) );
		return rc;
	}

	/* Session key is the hash of the shared secret */
	ctx = malloc ( digest->ctxsize );
	if ( ! ctx )
		return -ENOMEM;
	digest_init ( digest, ctx );
	digest_update ( digest, ctx, shared, exchange->sharedsize );
	digest_final ( digest, ctx, auth->session_key );
	free ( ctx );

	auth->dhvlen = exchange->pubsize;
	return 0;
}

/**
 * Send an authentication command
 *
 * @v nvmetcp		NVMe/TCP session
 * @v fctype		Fabric command type (AuthSend or AuthReceive)
 * @v data		Command data, or NULL
 * @v data_len		Length of command data
 * @v recv_len		Expected length of returned data
 * @ret rc		Return status code
 */
static int nvmetcp_auth_tx_command ( struct nvmetcp_session *nvmetcp,
				     unsigned int fctype,
				     const void *data, size_t data_len,
				     size_t recv_len ) {
	union nvme_command *cmd = &nvmetcp->cmd;

	/* Construct command */
	memset ( cmd, 0, sizeof ( *cmd ) );
	cmd->auth.opcode = NVMF_OPCODE;
	cmd->auth.command_id = cpu_to_le16 ( ++nvmetcp->cid );
	cmd->auth.fctype = fctype;
	cmd->auth.secp = NVME_AUTH_DHCHAP_PROTOCOL_IDENTIFIER;
	cmd->auth.spsp0 = 0x01;
	cmd->auth.spsp1 = 0x01;
	/* For AuthSend, al_tl is the length of the data being sent; for
	 * AuthReceive, it is the allocation length of the receive buffer.
	 * nvmet rejects an AuthReceive with a zero al_tl (INVALID_FIELD |
	 * DNR, Ubuntu 7.0) and requires al_tl >= transfer length.
	 */
	cmd->auth.al_tl = cpu_to_le32 ( data_len ? data_len : recv_len );

	return nvmetcp_tx_command ( nvmetcp, &nvmetcp->socket, cmd, data,
				 data_len, recv_len );
}

/**
 * Send AuthSend command
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Authentication data
 * @v data_len		Length of authentication data
 * @ret rc		Return status code
 */
static int nvmetcp_auth_tx_send ( struct nvmetcp_session *nvmetcp,
				  const void *data, size_t data_len ) {

	return nvmetcp_auth_tx_command ( nvmetcp, NVMF_FCTYPE_AUTH_SEND,
					 data, data_len, 0 );
}

/**
 * Send AuthReceive command
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_auth_tx_receive ( struct nvmetcp_session *nvmetcp ) {

	return nvmetcp_auth_tx_command ( nvmetcp, NVMF_FCTYPE_AUTH_RECEIVE,
					 NULL, 0, NVMETCP_AUTH_RECV_LEN );
}

/**
 * Send AuthReceive command and advance the authentication step
 *
 * @v nvmetcp		NVMe/TCP session
 * @v next_step		Step to enter once the command is sent
 * @ret rc		Return status code
 *
 * The step is advanced to @c next_step only if the command is sent
 * successfully.  If the send fails (e.g. the TCP window is closed),
 * the step is reset to the corresponding COMPLETE step so that the
 * command can be retried from nvmetcp_auth_step() when the window
 * opens again.
 */
static int nvmetcp_auth_tx_receive_step ( struct nvmetcp_session *nvmetcp,
					  unsigned int next_step ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	int rc;

	auth->step = next_step;
	if ( ( rc = nvmetcp_auth_tx_receive ( nvmetcp ) ) != 0 ) {
		/* Command not sent: reset the step for retry */
		auth->step = ( next_step == NVMETCP_AUTH_STEP_CHALLENGE ) ?
			     NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE :
			     NVMETCP_AUTH_STEP_COMPLETE_REPLY;
		return rc;
	}
	/* Record the command identifier of the AuthReceive now on the wire */
	auth->rx_cid = nvmetcp->cid;
	return 0;
}

/**
 * Send AuthSend(Negotiate)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_auth_tx_negotiate ( struct nvmetcp_session *nvmetcp ) {
	struct {
		struct nvmf_auth_dhchap_negotiate_data data;
		union nvmf_auth_protocol protocol;
	} __attribute__ (( packed )) negotiate;
	struct nvmf_auth_dhchap_protocol_descriptor *dhchap;
	uint8_t *idlist;
	int rc;

	/* Construct Negotiate data (single DH-HMAC-CHAP protocol) */
	memset ( &negotiate, 0, sizeof ( negotiate ) );
	negotiate.data.auth_type = NVME_AUTH_COMMON_MESSAGES;
	negotiate.data.auth_id = NVME_AUTH_DHCHAP_MESSAGE_NEGOTIATE;
	negotiate.data.t_id = cpu_to_le16 ( nvmetcp->auth.transaction );
	negotiate.data.sc_c = NVME_AUTH_SECP_NOSC;
	negotiate.data.napd = 1;
	dhchap = &negotiate.protocol.dhchap;
	dhchap->authid = NVME_AUTH_DHCHAP_AUTH_ID;
	dhchap->halen = 3;
	idlist = dhchap->idlist;
	idlist[0] = NVME_AUTH_HASH_SHA256;
	idlist[1] = NVME_AUTH_HASH_SHA384;
	idlist[2] = NVME_AUTH_HASH_SHA512;
	idlist[NVME_AUTH_DHCHAP_MAX_DH_IDS + 0] = NVME_AUTH_DHGROUP_NULL;
	idlist[NVME_AUTH_DHCHAP_MAX_DH_IDS + 1] = NVME_AUTH_DHGROUP_2048;
	idlist[NVME_AUTH_DHCHAP_MAX_DH_IDS + 2] = NVME_AUTH_DHGROUP_3072;
	idlist[NVME_AUTH_DHCHAP_MAX_DH_IDS + 3] = NVME_AUTH_DHGROUP_4096;
	dhchap->dhlen = 4;

	/* Send */
	if ( ( rc = nvmetcp_auth_tx_send ( nvmetcp, &negotiate,
					   sizeof ( negotiate ) ) ) != 0 )
		return rc;
	DBGC ( nvmetcp, "sent Negotiate\n" );
	return 0;
}

/**
 * Send AuthSend(Reply)
 *
 * @v nvmetcp		NVMe/TCP session
 * @v digest		Digest algorithm
 * @v exchange		Key exchange algorithm, or NULL
 * @ret rc		Return status code
 */
static int nvmetcp_auth_tx_reply ( struct nvmetcp_session *nvmetcp,
				   struct digest_algorithm *digest,
				   struct exchange_algorithm *exchange ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	struct nvmf_auth_dhchap_reply_data *reply =
		( struct nvmf_auth_dhchap_reply_data * ) nvmetcp->cmd_buf;
	uint8_t secret[NVME_AUTH_MAX_DIGEST_SIZE + 4];
	uint8_t key[NVME_AUTH_MAX_DIGEST_SIZE];
	uint8_t challenge[NVME_AUTH_MAX_DIGEST_SIZE];
	uint8_t response[NVME_AUTH_MAX_DIGEST_SIZE];
	size_t secret_len;
	size_t len = sizeof ( *reply );
	uint8_t hash_id;
	int rc;

	/* Parse and transform the secret */
	if ( ( rc = nvmetcp_auth_parse_secret ( nvmetcp, &hash_id, secret,
						&secret_len ) ) != 0 )
		return rc;
	if ( ( rc = nvmetcp_auth_transform_key ( nvmetcp,
						 nvmetcp_auth_hash ( hash_id ),
						 secret, secret_len, key ) ) != 0 )
		return rc;

	/* Calculate the (possibly augmented) challenge */
	memcpy ( challenge, auth->cval, auth->hl );
	if ( exchange ) {
		/* Ca = HMAC(Ks, C1) */
		if ( ( rc = nvmetcp_auth_hmac ( digest, auth->session_key,
						auth->hl, auth->cval, auth->hl,
						challenge ) ) != 0 )
			return rc;
	}

	/* Calculate the response */
	if ( ( rc = nvmetcp_auth_response ( nvmetcp, digest, key,
					    digest->digestsize, challenge,
					    response ) ) != 0 )
		return rc;

	/* Construct Reply data (single direction: no c2, no cvalid) */
	memset ( reply, 0, sizeof ( *reply ) );
	reply->auth_type = NVME_AUTH_DHCHAP_MESSAGES;
	reply->auth_id = NVME_AUTH_DHCHAP_MESSAGE_REPLY;
	reply->t_id = cpu_to_le16 ( auth->transaction );
	reply->hl = auth->hl;
	reply->dhvlen = cpu_to_le16 ( exchange ? auth->dhvlen : 0 );
	/* One-way authentication: s2 is zero, per NVMe base spec */
	reply->seqnum = cpu_to_le32 ( 0 );
	memcpy ( reply->rval, response, auth->hl );
	len += auth->hl;
	if ( exchange ) {
		/* The reply layout is rval || cval || dhvalue; the cval
		 * field must be present even when no C2 challenge is
		 * carried (cvalid clear), since the controller always
		 * parses the DH value at a fixed offset.
		 */
		memcpy ( reply->rval + auth->hl, auth->cval, auth->hl );
		len += auth->hl;
		memcpy ( reply->rval + 2 * auth->hl, auth->pub_key,
			 auth->dhvlen );
		len += auth->dhvlen;
	}

	/* Send */
	if ( ( rc = nvmetcp_auth_tx_send ( nvmetcp, reply, len ) ) != 0 )
		return rc;
	DBGC ( nvmetcp, "sent Reply\n" );
	return 0;
}

/**
 * Validate received authentication message
 *
 * @v nvmetcp		NVMe/TCP session
 * @v expected		Expected message identifier
 * @ret rc		Return status code
 */
static int nvmetcp_auth_rx_validate ( struct nvmetcp_session *nvmetcp,
				      uint8_t expected ) {
	struct nvmf_auth_dhchap_failure_data *failure =
		( struct nvmf_auth_dhchap_failure_data * ) nvmetcp->cmd_buf;

	/* Handle failure message */
	if ( ( failure->auth_type == NVME_AUTH_COMMON_MESSAGES ) &&
	     ( failure->auth_id == NVME_AUTH_DHCHAP_MESSAGE_FAILURE1 ) ) {
		DBGC ( nvmetcp, "authentication failed (reason %#x)\n",
		       failure->rescode_exp );
		return -EACCES;
	}

	/* Validate message type and identifier */
	if ( ( failure->auth_type != NVME_AUTH_DHCHAP_MESSAGES ) ||
	     ( failure->auth_id != expected ) ) {
		DBGC ( nvmetcp, "unexpected authentication message "
		       "%#x/%#x\n", failure->auth_type, failure->auth_id );
		return -EPROTO;
	}

	/* Validate transaction identifier */
	if ( le16_to_cpu ( failure->t_id ) != nvmetcp->auth.transaction ) {
		DBGC ( nvmetcp, "unexpected transaction identifier %d\n",
		       le16_to_cpu ( failure->t_id ) );
		return -EPROTO;
	}

	return 0;
}

/**
 * Process received challenge data
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_auth_rx_challenge ( struct nvmetcp_session *nvmetcp ) {
	struct nvmf_auth_dhchap_challenge_data *challenge =
		( struct nvmf_auth_dhchap_challenge_data * ) nvmetcp->cmd_buf;
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	struct digest_algorithm *digest;
	struct exchange_algorithm *exchange = NULL;
	uint16_t dhvlen;
	int rc;

	/* Validate message */
	if ( ( rc = nvmetcp_auth_rx_validate ( nvmetcp,
					       NVME_AUTH_DHCHAP_MESSAGE_CHALLENGE ) ) != 0 )
		return rc;

	/* Select hash algorithm */
	digest = nvmetcp_auth_hash ( challenge->hashid );
	if ( ! digest ) {
		DBGC ( nvmetcp, "unsupported hash identifier %#x\n",
		       challenge->hashid );
		return -EPROTO;
	}
	auth->hash_id = challenge->hashid;
	auth->hl = digest->digestsize;
	if ( challenge->hl != auth->hl ) {
		DBGC ( nvmetcp, "invalid hash length %d\n", challenge->hl );
		return -EPROTO;
	}

	/* Select DH group */
	dhvlen = le16_to_cpu ( challenge->dhvlen );
	if ( challenge->dhgid != NVME_AUTH_DHGROUP_NULL ) {
		exchange = nvmetcp_auth_exchange ( challenge->dhgid );
		if ( ! exchange ) {
			DBGC ( nvmetcp, "unsupported DH group %#x\n",
			       challenge->dhgid );
			return -EPROTO;
		}
		if ( dhvlen != exchange->pubsize ) {
			DBGC ( nvmetcp, "invalid DH value length %d\n",
			       dhvlen );
			return -EPROTO;
		}
	} else if ( dhvlen != 0 ) {
		DBGC ( nvmetcp, "invalid DH value length %d\n", dhvlen );
		return -EPROTO;
	}

	/* Save challenge and sequence number */
	auth->dhgid = challenge->dhgid;
	auth->seqnum = le32_to_cpu ( challenge->seqnum );
	memcpy ( auth->cval, challenge->cval, auth->hl );

	/* Generate DH keys and session key if required */
	if ( exchange ) {
		if ( ( rc = nvmetcp_auth_dh_key ( nvmetcp, exchange, digest,
						  challenge->cval + auth->hl ) ) != 0 )
			return rc;
	}

	/* Send Reply */
	return nvmetcp_auth_tx_reply ( nvmetcp, digest, exchange );
}

/**
 * Process received success1 data
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_auth_rx_success1 ( struct nvmetcp_session *nvmetcp ) {
	struct nvmf_auth_dhchap_success1_data *success1 =
		( struct nvmf_auth_dhchap_success1_data * ) nvmetcp->cmd_buf;
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	int rc;

	/* Validate message */
	if ( ( rc = nvmetcp_auth_rx_validate ( nvmetcp,
					       NVME_AUTH_DHCHAP_MESSAGE_SUCCESS1 ) ) != 0 )
		return rc;

	/* Validate hash length */
	if ( success1->hl != auth->hl ) {
		DBGC ( nvmetcp, "invalid hash length %d\n", success1->hl );
		return -EPROTO;
	}

	/* A controller response would require bidirectional authentication,
	 * which is not supported */
	if ( success1->rvalid ) {
		DBGC ( nvmetcp, "unexpected controller response\n" );
		return -EPROTO;
	}

	DBGC ( nvmetcp, "authentication succeeded\n" );
	auth->completed = 1;
	return 0;
}

/**
 * Complete the authentication phase if possible
 *
 * @v nvmetcp		NVMe/TCP session
 *
 * The authentication phase ends only once both the success1 data and
 * the AuthReceive completion have been received, since they may
 * arrive in either order (possibly within the same TCP segment).
 */
void nvmetcp_auth_try_complete ( struct nvmetcp_session *nvmetcp ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;

	if ( auth->completed && auth->rx_complete )
		nvmetcp->phase = NVMETCP_PHASE_PROP_SET;
}

/**
 * Step DH-HMAC-CHAP authentication
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
int nvmetcp_auth_step ( struct nvmetcp_session *nvmetcp ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	int rc;

	switch ( auth->step ) {
	case NVMETCP_AUTH_STEP_START:
		/* Do not restart authentication once the success1 data has
		 * been validated: the session is only awaiting the final
		 * AuthReceive completion (or the phase advancement)
		 */
		if ( auth->completed )
			return 0;
		/* Start authentication: send Negotiate */
		if ( ( rc = get_random_nz ( &auth->transaction,
					    sizeof ( auth->transaction ) ) ) != 0 )
			return rc;
		auth->step = NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE;
		return nvmetcp_auth_tx_negotiate ( nvmetcp );
	case NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE:
	case NVMETCP_AUTH_STEP_COMPLETE_REPLY:
		/* AuthReceive deferred while the TCP window was closed:
		 * retry now that the window is available.  (The command is
		 * not in flight: the failed send did not reach the wire.)
		 */
		if ( ! nvmetcp->tx_in_flight )
			return nvmetcp_auth_tx_receive_step ( nvmetcp,
					( auth->step == NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE ) ?
					NVMETCP_AUTH_STEP_CHALLENGE :
					NVMETCP_AUTH_STEP_SUCCESS1 );
		return 0;
	default:
		/* Command in flight: wait for completion */
		return 0;
	}
}

/**
 * Handle completion of an authentication command
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
int nvmetcp_auth_rx_complete ( struct nvmetcp_session *nvmetcp ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;

	switch ( auth->step ) {
	case NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE:
		/* Negotiate complete: receive challenge */
		return nvmetcp_auth_tx_receive_step ( nvmetcp,
						      NVMETCP_AUTH_STEP_CHALLENGE );
	case NVMETCP_AUTH_STEP_CHALLENGE:
		/* AuthReceive complete: wait for data */
		return 0;
	case NVMETCP_AUTH_STEP_SUCCESS1:
	case NVMETCP_AUTH_STEP_START:
		/* Final AuthReceive complete, identified by its command
		 * identifier: a Reply completion may be processed after the
		 * AuthReceive has been sent (following a TCP window retry),
		 * and must not be mistaken for the AuthReceive completion.
		 */
		if ( le16_to_cpu ( nvmetcp->cqe.command_id ) != auth->rx_cid )
			return 0;
		/* This completion ends the authentication phase (the phase
		 * is advanced by nvmetcp_auth_try_complete() once the
		 * success1 data has also been validated)
		 */
		auth->rx_complete = 1;
		return 0;
	case NVMETCP_AUTH_STEP_COMPLETE_REPLY:
		/* Reply complete: receive success1 */
		return nvmetcp_auth_tx_receive_step ( nvmetcp,
						      NVMETCP_AUTH_STEP_SUCCESS1 );
	default:
		DBGC ( nvmetcp, "unexpected completion in step %d\n",
		       auth->step );
		return -EPROTO;
	}
}

/**
 * Handle received authentication data
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
int nvmetcp_auth_rx_data ( struct nvmetcp_session *nvmetcp ) {
	struct nvmetcp_auth *auth = &nvmetcp->auth;
	int rc;

	switch ( auth->step ) {
	case NVMETCP_AUTH_STEP_CHALLENGE:
		/* Challenge data received: process and send Reply */
		if ( ( rc = nvmetcp_auth_rx_challenge ( nvmetcp ) ) != 0 )
			return rc;
		auth->step = NVMETCP_AUTH_STEP_COMPLETE_REPLY;
		return 0;
	case NVMETCP_AUTH_STEP_SUCCESS1:
		/* Success1 data received: validate and finish */
		if ( ( rc = nvmetcp_auth_rx_success1 ( nvmetcp ) ) != 0 )
			return rc;
		auth->step = NVMETCP_AUTH_STEP_START;
		return 0;
	default:
		DBGC ( nvmetcp, "unexpected data in step %d\n", auth->step );
		return -EPROTO;
	}
}
