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
 * NVMe-over-TCP session layer, modelled on the Linux kernel NVMe-over-TCP
 * implementation (drivers/nvme/host/tcp.c, GPL-2.0).
 */

FILE_LICENCE ( GPL2_ONLY );

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <assert.h>
#include <byteswap.h>
#include <ipxe/socket.h>
#include <ipxe/iobuf.h>
#include <ipxe/uri.h>
#include <ipxe/xfer.h>
#include <ipxe/open.h>
#include <ipxe/process.h>
#include <ipxe/tcpip.h>
#include <ipxe/settings.h>
#include <ipxe/uuid.h>
#include <ipxe/efi/efi_path.h>

/* Identify errors as coming from this file */
#undef ERRFILE
#define ERRFILE ERRFILE_nvmetcp

#include <ipxe/nvmetcp.h>
#include <ipxe/nbct.h>

/** Default host NQN prefix (uuid suffix appended) */
#define NVMETCP_DEFAULT_HOST_NQN "nqn.2014-08.org.ipxe:"

/* Disambiguate the various error causes */
#define EINVAL_NO_ROOT_PATH \
	__einfo_error ( EINFO_EINVAL_NO_ROOT_PATH )
#define EINFO_EINVAL_NO_ROOT_PATH \
	__einfo_uniqify ( EINFO_EINVAL, 0x01, "No root path specified" )
#define EINVAL_NO_TARGET \
	__einfo_error ( EINFO_EINVAL_NO_TARGET )
#define EINFO_EINVAL_NO_TARGET \
	__einfo_uniqify ( EINFO_EINVAL, 0x02, "No target address specified" )
#define EINVAL_NO_SUBSYSTEM_NQN \
	__einfo_error ( EINFO_EINVAL_NO_SUBSYSTEM_NQN )
#define EINFO_EINVAL_NO_SUBSYSTEM_NQN \
	__einfo_uniqify ( EINFO_EINVAL, 0x03, "No subsystem NQN specified" )

/**
 * Free NVMe/TCP session
 *
 * @v refcnt		Reference count
 */
static void nvmetcp_free ( struct refcnt *refcnt ) {
	struct nvmetcp_session *nvmetcp =
		container_of ( refcnt, struct nvmetcp_session, refcnt );

	free ( nvmetcp->target_host );
	free ( nvmetcp->subsystem_nqn );
	free ( nvmetcp->host_nqn );
	free ( nvmetcp->secret );
	uri_put ( nvmetcp->uri );
	free ( nvmetcp );
}

/**
 * Close NVMe/TCP session
 *
 * @v nvmetcp		NVMe/TCP session
 * @v rc		Reason for close
 */
static void nvmetcp_close ( struct nvmetcp_session *nvmetcp, int rc ) {

	/* A TCP graceful close is still an error from our point of view */
	if ( rc == 0 )
		rc = -ECONNRESET;

	DBGC ( nvmetcp, "closed: %s (phase %d)\n", strerror ( rc ),
	       nvmetcp->phase );

	/* Fail any deferred capacity request */
	if ( nvmetcp->capacity_data ) {
		nvmetcp->capacity_data = NULL;
		intf_restart ( &nvmetcp->data, rc );
	}

	/* Stop transmission process */
	process_del ( &nvmetcp->process );

	/* Shut down interfaces */
	intfs_shutdown ( rc, &nvmetcp->socket, &nvmetcp->io_socket,
			 &nvmetcp->control, &nvmetcp->data, NULL );
}

/**
 * Reset receive state to expect a new PDU header
 *
 * @v nvmetcp		NVMe/TCP session
 */
static void nvmetcp_rx_reset ( struct nvmetcp_rx *rx ) {

	rx->hdr_len = 0;
	rx->hdr_expect = 8;
	rx->data_expect = 0;
	rx->data_len = 0;
}

/**
 * Send data over the socket
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Data to send
 * @v len		Length of data
 * @ret rc		Return status code
 */
static int nvmetcp_tx_data ( struct nvmetcp_session *nvmetcp,
			     struct interface *socket,
			     const void *data, size_t len ) {
	struct io_buffer *iobuf;

	/* Check window */
	if ( xfer_window ( socket ) < ( size_t ) len ) {
		DBGC2 ( nvmetcp, "waiting for window (%zd)\n", len );
		return -EAGAIN;
	}

	/* Send data */
	iobuf = alloc_iob ( len );
	if ( ! iobuf )
		return -ENOMEM;
	memcpy ( iob_put ( iobuf, len ), data, len );
	DBGC ( nvmetcp, "sending %zd bytes\n", len );
	xfer_deliver_iob ( socket, iobuf );

	/* The request is now in flight */
	nvmetcp->tx_in_flight = 1;

	/* Stop stepping until a response arrives */
	process_del ( &nvmetcp->process );

	return 0;
}

/**
 * Send a PDU with optional in-capsule data
 *
 * @v nvmetcp		NVMe/TCP session
 * @v hdr		PDU header
 * @v hdr_len		Length of PDU header
 * @v data		In-capsule data, or NULL
 * @v data_len		Length of in-capsule data
 * @ret rc		Return status code
 *
 * The PDU header and any in-capsule data are combined into a single
 * I/O buffer so that they are delivered to the TCP layer in one
 * atomic call.  This is required because iPXE's TCP implementation
 * allows only one unacknowledged packet in the transmit queue at a
 * time: a second xfer_deliver_iob() before the first is acknowledged
 * would see a zero window and fail with -EAGAIN, causing the caller
 * to retry and resend the entire PDU header.
 *
 * The window check tests only that the connection is established and
 * the transmit queue is empty (xfer_window() != 0).  It does not
 * require the window to be large enough for the entire PDU: the TCP
 * layer fragments and retransmits queued data as the window opens.
 */
static int nvmetcp_tx_pdu ( struct nvmetcp_session *nvmetcp,
			    struct interface *socket,
			    const void *hdr, size_t hdr_len,
			    const void *data, size_t data_len ) {
	struct io_buffer *iobuf;
	size_t total = ( hdr_len + data_len );

	/* Check that the TCP window is available */
	if ( xfer_window ( socket ) == 0 ) {
		DBGC2 ( nvmetcp, "waiting for window (%zd)\n", total );
		return -EAGAIN;
	}

	/* Allocate combined I/O buffer */
	iobuf = alloc_iob ( total );
	if ( ! iobuf )
		return -ENOMEM;

	/* Copy PDU header and in-capsule data into a single buffer */
	memcpy ( iob_put ( iobuf, hdr_len ), hdr, hdr_len );
	if ( data_len )
		memcpy ( iob_put ( iobuf, data_len ), data, data_len );

	DBGC ( nvmetcp, "sending %zd bytes\n", total );
	xfer_deliver_iob ( socket, iobuf );

	/* The request is now in flight */
	nvmetcp->tx_in_flight = 1;

	/* Stop stepping until a response arrives */
	process_del ( &nvmetcp->process );

	return 0;
}

/**
 * Send a command PDU
 *
 * @v nvmetcp		NVMe/TCP session
 * @v cmd		NVMe command
 * @v data		Command data (in-capsule), or NULL
 * @v data_len		Length of command data
 * @v recv_len		Expected length of returned data
 * @ret rc		Return status code
 */
int nvmetcp_tx_command ( struct nvmetcp_session *nvmetcp,
			 struct interface *socket,
			 union nvme_command *cmd, const void *data,
			 size_t data_len, size_t recv_len ) {
	struct nvmetcp_cmd_pdu pdu;
	struct nvme_sgl_desc *sgl = &pdu.cmd.common.dptr.sgl;
	int rc;

	/* Construct PDU */
	memset ( &pdu, 0, sizeof ( pdu ) );
	pdu.hdr.type = NVMETCP_PDU_COMMAND;
	pdu.hdr.hlen = sizeof ( pdu );
	pdu.hdr.pdo = ( data_len ? sizeof ( pdu ) : 0 );
	pdu.hdr.plen = cpu_to_le32 ( sizeof ( pdu ) + data_len );
	pdu.cmd = *cmd;

	/* Fill in SGL descriptor (required by the TCP transport) */
	pdu.cmd.common.flags |= NVME_CMD_SGL_METABUF;
	if ( data_len ) {
		sgl->addr = 0; /* no in-capsule data alignment requirement */
		sgl->length = cpu_to_le32 ( data_len );
		sgl->type = ( NVME_SGL_FMT_DATA_DESC << 4 ) |
			    NVME_SGL_FMT_OFFSET;
	} else {
		/* Out-capsule data: SGL describes the data to be returned */
		sgl->addr = 0;
		sgl->length = cpu_to_le32 ( recv_len );
		sgl->type = ( NVME_TRANSPORT_SGL_DATA_DESC << 4 ) |
			    NVME_SGL_FMT_TRANSPORT_A;
	}

	/* Send PDU header and command (with any in-capsule data) */
	if ( ( rc = nvmetcp_tx_pdu ( nvmetcp, socket, &pdu, sizeof ( pdu ),
				     data, data_len ) ) != 0 )
		return rc;

	/* Prepare to receive response (and returned data) */
	nvmetcp->cmd_data_len = recv_len;
	nvmetcp->cmd_data_offset = 0;
	nvmetcp_rx_reset ( ( socket == &nvmetcp->socket ) ?
			   &nvmetcp->rx : &nvmetcp->rx_io );

	return 0;
}

/**
 * Send ICReq PDU
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_tx_icreq ( struct nvmetcp_session *nvmetcp,
			      struct interface *socket ) {
	struct nvmetcp_icreq icreq;

	DBGC ( nvmetcp, "sending ICReq\n" );

	/* Construct ICReq (128 bytes on the wire) */
	memset ( &icreq, 0, sizeof ( icreq ) );
	icreq.hdr.type = NVMETCP_PDU_ICREQ;
	icreq.hdr.hlen = sizeof ( icreq );
	icreq.hdr.plen = cpu_to_le32 ( sizeof ( icreq ) );
	icreq.pfv = cpu_to_le16 ( NVMETCP_PFV );
	icreq.maxr2t = 0; /* single in-flight R2T */
	icreq.hpda = 0; /* no alignment constraint */
	icreq.digest = 0; /* no digests for now */

	return nvmetcp_tx_data ( nvmetcp, socket, &icreq, sizeof ( icreq ) );
}

/**
 * Send Connect command
 *
 * @v nvmetcp		NVMe/TCP session
 * @v qid		Queue identifier
 * @ret rc		Return status code
 */
static int nvmetcp_tx_connect ( struct nvmetcp_session *nvmetcp,
				struct interface *socket,
				unsigned int qid ) {
	union nvme_command *cmd = &nvmetcp->cmd;
	struct nvmf_connect_data data;
	union uuid uuid;

	DBGC ( nvmetcp, "sending Connect (qid %d)\n", qid );

	/* Construct Connect command */
	memset ( cmd, 0, sizeof ( *cmd ) );
	cmd->connect.opcode = NVMF_OPCODE;
	cmd->connect.command_id = cpu_to_le16 ( ++nvmetcp->cid );
	cmd->connect.fctype = NVMF_FCTYPE_CONNECT;
	cmd->connect.qid = cpu_to_le16 ( qid );
	cmd->connect.sqsize = cpu_to_le16 ( 1 ); /* single command depth */
	cmd->connect.kato = 0; /* no keep-alive (boot-time session) */

	/* Construct Connect data */
	memset ( &data, 0, sizeof ( data ) );
	data.cntlid = cpu_to_le16 ( qid ? nvmetcp->cntlid : 0xffff );
	if ( fetch_uuid_setting ( NULL, &uuid_setting, &uuid ) == 0 )
		memcpy ( data.hostid, &uuid, sizeof ( uuid ) );
	strncpy ( data.subsysnqn, nvmetcp->subsystem_nqn,
		  sizeof ( data.subsysnqn ) - 1 );
	strncpy ( data.hostnqn, nvmetcp->host_nqn,
		  sizeof ( data.hostnqn ) - 1 );

	return nvmetcp_tx_command ( nvmetcp, socket, cmd, &data,
				 sizeof ( data ), 0 );
}

/**
 * Send Property Set command (enable controller)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 *
 * The NVMe-over-Fabrics specification requires the host to enable the
 * controller (via the CC register) before issuing any further
 * commands.  nvmet rejects commands sent while CC.EN is clear with
 * CMD_SEQ_ERROR.
 */
static int nvmetcp_tx_prop_set ( struct nvmetcp_session *nvmetcp ) {
	union nvme_command *cmd = &nvmetcp->cmd;

	DBGC ( nvmetcp, "sending Property Set (CC)\n" );

	/* Construct Property Set command */
	memset ( cmd, 0, sizeof ( *cmd ) );
	cmd->prop_set.opcode = NVMF_OPCODE;
	cmd->prop_set.command_id = cpu_to_le16 ( ++nvmetcp->cid );
	cmd->prop_set.fctype = NVMF_FCTYPE_PROPERTY_SET;
	cmd->prop_set.offset = cpu_to_le32 ( NVME_REG_CC );
	cmd->prop_set.value = cpu_to_le64 (
		NVME_CC_ENABLE |
		( NVME_NVM_IOSQES << NVME_CC_IOSQES_SHIFT ) |
		( NVME_NVM_IOCQES << NVME_CC_IOCQES_SHIFT ) );

	return nvmetcp_tx_command ( nvmetcp, &nvmetcp->socket, cmd, NULL, 0, 0 );
}

/**
 * Send Identify command
 *
 * @v nvmetcp		NVMe/TCP session
 * @v cns		Identify CNS value
 * @v nsid		Namespace identifier
 * @ret rc		Return status code
 */
static int nvmetcp_tx_identify ( struct nvmetcp_session *nvmetcp,
				 uint8_t cns, uint32_t nsid ) {
	union nvme_command *cmd = &nvmetcp->cmd;

	DBGC ( nvmetcp, "sending Identify (cns %#x nsid %#x)\n", cns, nsid );

	/* Construct Identify command */
	memset ( cmd, 0, sizeof ( *cmd ) );
	cmd->identify.opcode = NVME_OPCODE_IDENTIFY;
	cmd->identify.command_id = cpu_to_le16 ( ++nvmetcp->cid );
	cmd->identify.cns = cns;
	cmd->identify.nsid = cpu_to_le32 ( nsid );

	return nvmetcp_tx_command ( nvmetcp, &nvmetcp->socket, cmd, NULL, 0,
				    NVME_IDENTIFY_DATA_SIZE );
}

/**
 * Send H2CData PDU in response to an R2T
 *
 * @v nvmetcp		NVMe/TCP session
 * @v r2t		R2T PDU (received header)
 * @ret rc		Return status code
 */
static int nvmetcp_tx_h2cdata ( struct nvmetcp_session *nvmetcp,
				struct nvmetcp_r2t_pdu *r2t ) {
	struct nvmetcp_data_pdu pdu;
	uint32_t offset = le32_to_cpu ( r2t->r2t_offset );
	uint32_t length = le32_to_cpu ( r2t->r2t_length );

	/* Sanity check */
	if ( ( offset + length ) > nvmetcp->block_len ) {
		DBGC ( nvmetcp, "R2T out of range (offset %d length %d)\n",
		       offset, length );
		return -EPROTO;
	}

	/* Construct H2CData PDU */
	memset ( &pdu, 0, sizeof ( pdu ) );
	pdu.hdr.type = NVMETCP_PDU_H2CDATA;
	pdu.hdr.hlen = sizeof ( pdu );
	pdu.hdr.pdo = sizeof ( pdu );
	pdu.hdr.plen = cpu_to_le32 ( sizeof ( pdu ) + length );
	pdu.command_id = r2t->command_id;
	pdu.ttag = r2t->ttag;
	pdu.data_offset = r2t->r2t_offset;
	pdu.data_length = r2t->r2t_length;

	/* Send H2CData PDU (header and data as a single buffer) */
	return nvmetcp_tx_pdu ( nvmetcp, &nvmetcp->io_socket, &pdu, sizeof ( pdu ),
				( ( uint8_t * ) nvmetcp->block_buffer ) +
				offset, length );
}

/**
 * Process received PDU header
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_rx_header ( struct nvmetcp_session *nvmetcp,
				struct nvmetcp_rx *rx ) {
	struct nvmetcp_pdu_header *hdr =
		( struct nvmetcp_pdu_header * ) rx->hdr;

	/* Determine header and data lengths for this PDU type */
	DBGC2 ( nvmetcp, "received PDU type %#x len %zd\n", hdr->type,
		rx->hdr_len );
	switch ( hdr->type ) {
	case NVMETCP_PDU_ICREQ:
	case NVMETCP_PDU_ICRESP:
		rx->hdr_expect = 128;
		break;
	case NVMETCP_PDU_COMMAND:
		rx->hdr_expect = hdr->hlen;
		break;
	case NVMETCP_PDU_RESPONSE:
		rx->hdr_expect = sizeof ( struct nvmetcp_rsp_pdu );
		break;
	case NVMETCP_PDU_C2HDATA:
		rx->hdr_expect = sizeof ( struct nvmetcp_data_pdu );
		break;
	case NVMETCP_PDU_R2T:
		rx->hdr_expect = sizeof ( struct nvmetcp_r2t_pdu );
		break;
	case NVMETCP_PDU_H2CTERM:
	case NVMETCP_PDU_C2HTERM:
		DBGC ( nvmetcp, "received terminate PDU\n" );
		return -EPROTO;
	default:
		DBGC ( nvmetcp, "unrecognised PDU type %#x\n", hdr->type );
		return -EPROTO;
	}

	return 0;
}

/**
 * Process complete PDU (header and data received)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_rx_command ( struct nvmetcp_session *nvmetcp );
static int nvmetcp_rx_data ( struct nvmetcp_session *nvmetcp );
static int nvmetcp_open_socket ( struct nvmetcp_session *nvmetcp,
				 struct interface *socket,
				 struct nvmetcp_rx *rx,
				 unsigned int phase );

static int nvmetcp_rx_pdu ( struct nvmetcp_session *nvmetcp,
			    struct nvmetcp_rx *rx ) {
	struct nvmetcp_pdu_header *hdr =
		( struct nvmetcp_pdu_header * ) rx->hdr;
	struct nvmetcp_rsp_pdu *rsp =
		( struct nvmetcp_rsp_pdu * ) rx->hdr;
	struct nvmetcp_data_pdu *data =
		( struct nvmetcp_data_pdu * ) rx->hdr;
	uint32_t plen = le32_to_cpu ( hdr->plen );
	size_t data_len;

	/* Handle PDU-specific header */
	switch ( hdr->type ) {
	case NVMETCP_PDU_ICRESP: {
		struct nvmetcp_icresp *icresp =
			( struct nvmetcp_icresp * ) rx->hdr;

		/* Validate ICResp */
		if ( icresp->pfv != cpu_to_le16 ( NVMETCP_PFV ) ) {
			DBGC ( nvmetcp, "unsupported protocol version %#x\n",
			       le16_to_cpu ( icresp->pfv ) );
			return -EPROTO;
		}
		nvmetcp->pfv = le16_to_cpu ( icresp->pfv );
		nvmetcp->maxdata = le32_to_cpu ( icresp->maxdata );
		nvmetcp->hdr_digest = ( icresp->digest & NVMETCP_DIGEST_HDR );
		nvmetcp->data_digest = ( icresp->digest & NVMETCP_DIGEST_DATA );
		DBGC ( nvmetcp, "ICResp: maxdata %d digests %d/%d\n",
		       nvmetcp->maxdata, nvmetcp->hdr_digest,
		       nvmetcp->data_digest );
		if ( rx == &nvmetcp->rx_io ) {
			/* I/O queue connection established: send Connect */
			nvmetcp->phase = NVMETCP_PHASE_CONNECT_IO;
		} else {
			/* Admin queue connection established: send Connect */
			nvmetcp->phase = NVMETCP_PHASE_CONNECT_ADMIN;
		}
		/* The ICReq is no longer in flight */
		nvmetcp->tx_in_flight = 0;
		/* Resume stepping to send the Connect command */
		process_add ( &nvmetcp->process );
		return 0;
	}
	case NVMETCP_PDU_RESPONSE:
		/* Save completion */
		nvmetcp->cqe = rsp->cqe;
		DBGC2 ( nvmetcp, "completion: cid %d status %#x\n",
			le16_to_cpu ( rsp->cqe.command_id ),
			le16_to_cpu ( rsp->cqe.status ) );
		return 0;
	case NVMETCP_PDU_C2HDATA:
		/* Set up data receive */
		data_len = plen - sizeof ( struct nvmetcp_data_pdu );
		if ( data_len > NVMETCP_MAX_CMD_DATA ) {
			DBGC ( nvmetcp, "oversized data PDU (%zd)\n", data_len );
			return -EPROTO;
		}
		if ( le32_to_cpu ( data->data_offset ) !=
		     nvmetcp->cmd_data_offset ) {
			DBGC ( nvmetcp, "unexpected data offset %d (have %zd)\n",
			       le32_to_cpu ( data->data_offset ),
			       nvmetcp->cmd_data_offset );
			return -EPROTO;
		}
		/* Use the actual data length (the amount of returned data is
		 * not known in advance for variable-length commands such as
		 * authentication) */
		nvmetcp->cmd_data_len = nvmetcp->cmd_data_offset + data_len;
		rx->data_expect = data_len;
		return 0;
	case NVMETCP_PDU_R2T: {
		struct nvmetcp_r2t_pdu *r2t =
			( struct nvmetcp_r2t_pdu * ) rx->hdr;

		/* Write data requested: send H2CData */
		return nvmetcp_tx_h2cdata ( nvmetcp, r2t );
	}
	default:
		break;
	}

	return 0;
}

/**
 * Process complete PDU (header and any data received)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_rx_pdu_complete ( struct nvmetcp_session *nvmetcp,
				    struct nvmetcp_rx *rx ) {
	struct nvmetcp_pdu_header *hdr =
		( struct nvmetcp_pdu_header * ) rx->hdr;
	int rc;

	switch ( hdr->type ) {
	case NVMETCP_PDU_ICRESP:
		/* Handled in nvmetcp_rx_pdu() */
		break;
	case NVMETCP_PDU_RESPONSE:
		/* Command complete */
		if ( ( rc = nvmetcp_rx_command ( nvmetcp ) ) != 0 )
			return rc;
		break;
	case NVMETCP_PDU_C2HDATA:
		/* Data received (possibly fragmentary) */
		if ( nvmetcp->cmd_data_offset < nvmetcp->cmd_data_len )
			break; /* wait for more data PDUs */
		if ( ( rc = nvmetcp_rx_data ( nvmetcp ) ) != 0 )
			return rc;
		break;
	case NVMETCP_PDU_R2T:
		/* Handled in nvmetcp_rx_pdu() */
		break;
	default:
		DBGC ( nvmetcp, "unexpected complete PDU type %#x\n",
		       hdr->type );
		return -EPROTO;
	}

	/* Reset receive state for next PDU */
	nvmetcp_rx_reset ( rx );
	return 0;
}

/**
 * Handle authentication-required Connect completion
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_auth_required ( struct nvmetcp_session *nvmetcp ) {
	if ( ! nvmetcp->secret ) {
		DBGC ( nvmetcp, "authentication required but no secret\n" );
		return -EPERM;
	}
	DBGC ( nvmetcp, "authentication required\n" );
	nvmetcp->phase = NVMETCP_PHASE_AUTH;
	/* Resume stepping to send the first authentication message */
	process_add ( &nvmetcp->process );
	return 0;
}

/**
 * Process complete command (completion received)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_rx_command ( struct nvmetcp_session *nvmetcp ) {
	uint16_t status = le16_to_cpu ( nvmetcp->cqe.status );
	uint32_t result = le32_to_cpu ( nvmetcp->cqe.result.u32 );
	int rc;

	/* The command is no longer in flight */
	nvmetcp->tx_in_flight = 0;

	/* Check command status */
	if ( status != 0 ) {
		/* Authentication required is not an error: enter the
		 * authentication phase instead.  The Connect completion status
		 * NVME_SC_AUTH_REQUIRED alone is the trigger: nvmet (kernel
		 * 7.x) does not set the ATR bit in the result field for this
		 * status, only the spec-compliant path does.
		 */
		if ( ( status == NVME_SC_AUTH_REQUIRED ) &&
		     ( nvmetcp->phase == NVMETCP_PHASE_CONNECT_ADMIN ) )
			return nvmetcp_auth_required ( nvmetcp );
		DBGC ( nvmetcp, "command failed: status %#x\n", status );
		/* Fail the session if an authentication command failed */
		if ( nvmetcp->phase == NVMETCP_PHASE_AUTH )
			return -EIO;
		/* Fail any in-flight block command, keep session alive */
		if ( nvmetcp->block_data ) {
			nvmetcp->block_data = NULL;
			intf_restart ( &nvmetcp->data, -EIO );
			return 0;
		}
		/* Fail the session if a setup command failed */
		DBGC ( nvmetcp, "setup command failed in phase %d\n",
		       nvmetcp->phase );
		return -EIO;
	}

	switch ( nvmetcp->phase ) {
	case NVMETCP_PHASE_CONNECT_ADMIN:
		/* Record controller identifier for the I/O queue connect */
		nvmetcp->cntlid = ( result & 0xffff );
		/* Check whether authentication is required */
		if ( result & NVMF_CONNECT_AUTHREQ_ATR ) {
			if ( ( rc = nvmetcp_auth_required ( nvmetcp ) ) != 0 )
				return rc;
		} else {
			nvmetcp->phase = NVMETCP_PHASE_PROP_SET;
		}
		/* Resume stepping to send the next command */
		process_add ( &nvmetcp->process );
		return 0;
	case NVMETCP_PHASE_PROP_SET:
		/* Controller enabled */
		nvmetcp->phase = NVMETCP_PHASE_IDENTIFY_CTRL;
		/* Resume stepping to send the next command */
		process_add ( &nvmetcp->process );
		return 0;
	case NVMETCP_PHASE_IDENTIFY_CTRL:
		/* Controller identified, sending Identify Namespace */
		nvmetcp->phase = NVMETCP_PHASE_IDENTIFY_NS;
		/* Resume stepping to send the next command */
		process_add ( &nvmetcp->process );
		return 0;
	case NVMETCP_PHASE_IDENTIFY_NS:
		/* Namespace identified, opening I/O queue connection */
		if ( ( rc = nvmetcp_open_socket ( nvmetcp, &nvmetcp->io_socket,
						  &nvmetcp->rx_io,
						  NVMETCP_PHASE_ICREQ_IO ) ) != 0 )
			return rc;
		return 0;
	case NVMETCP_PHASE_AUTH:
		/* Authentication progress is handled by the auth module */
		if ( ( rc = nvmetcp_auth_rx_complete ( nvmetcp ) ) != 0 )
			return rc;
		/* End the authentication phase once both the success1 data
		 * and this completion have been received (they may arrive in
		 * either order within the same TCP segment; completing early
		 * would misprocess this completion as the Property Set
		 * completion and skip the Property Set entirely)
		 */
		nvmetcp_auth_try_complete ( nvmetcp );
		if ( nvmetcp->phase != NVMETCP_PHASE_AUTH )
			process_add ( &nvmetcp->process );
		return 0;
	case NVMETCP_PHASE_CONNECT_IO:
		DBGC ( nvmetcp, "I/O queue established\n" );
		nvmetcp->phase = NVMETCP_PHASE_READY;
		/* Complete any deferred capacity request */
		if ( nvmetcp->capacity_data ) {
			nvmetcp->capacity_data = NULL;
			block_capacity ( &nvmetcp->data, &nvmetcp->capacity );
			intf_restart ( &nvmetcp->data, 0 );
		}
		return 0;
	case NVMETCP_PHASE_READY:
		/* Block command complete */
		if ( nvmetcp->block_data ) {
			nvmetcp->block_data = NULL;
			intf_restart ( &nvmetcp->data, 0 );
		}
		return 0;
	default:
		DBGC ( nvmetcp, "unexpected completion in phase %d\n",
		       nvmetcp->phase );
		return -EPROTO;
	}
}

/**
 * Process complete data (returned data fully received)
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
static int nvmetcp_rx_data ( struct nvmetcp_session *nvmetcp ) {
	uint8_t *data = nvmetcp->cmd_buf;
	int rc;

	/* The command is no longer in flight */
	nvmetcp->tx_in_flight = 0;

	switch ( nvmetcp->phase ) {
	case NVMETCP_PHASE_AUTH:
		/* Authentication data is handled by the auth module */
		if ( ( rc = nvmetcp_auth_rx_data ( nvmetcp ) ) != 0 )
			return rc;
		/* End the authentication phase once both the success1 data
		 * and the AuthReceive completion have been received; they
		 * may arrive in either order
		 */
		nvmetcp_auth_try_complete ( nvmetcp );
		/* Resume stepping if authentication has completed */
		if ( nvmetcp->phase != NVMETCP_PHASE_AUTH )
			process_add ( &nvmetcp->process );
		return 0;
	case NVMETCP_PHASE_IDENTIFY_CTRL:
		DBGC ( nvmetcp, "controller identified\n" );
		/* Completion will advance the state machine */
		return 0;
	case NVMETCP_PHASE_IDENTIFY_NS:
		/* Parse Identify Namespace data */
		if ( ( rc = nvmetcp_identify_ns ( data,
						   &nvmetcp->capacity ) ) != 0 ) {
			DBGC ( nvmetcp, "invalid Identify Namespace data\n" );
			return rc;
		}
		DBGC ( nvmetcp, "namespace %d: %d blocks of %d bytes\n",
		       nvmetcp->nsid, ( unsigned int ) nvmetcp->capacity.blocks,
		       ( unsigned int ) nvmetcp->capacity.blksize );
		/* Completion will advance the state machine */
		return 0;
	case NVMETCP_PHASE_READY:
		/* Block read data complete */
		if ( nvmetcp->block_data && ! nvmetcp->block_writing ) {
			memcpy ( nvmetcp->block_buffer, nvmetcp->cmd_buf,
				 nvmetcp->block_len );
			nvmetcp->block_data = NULL;
			intf_restart ( &nvmetcp->data, 0 );
		}
		return 0;
	default:
		DBGC ( nvmetcp, "unexpected data in phase %d\n",
		       nvmetcp->phase );
		return -EPROTO;
	}
}

/**
 * Read capacity of NVMe namespace
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Block data interface
 * @ret rc		Return status code
 */
static int nvmetcp_block_read_capacity ( struct nvmetcp_session *nvmetcp,
					 struct interface *data ) {

	/* Attach command completion interface */
	intf_plug_plug ( &nvmetcp->data, data );

	/* If the I/O queue is not yet ready, defer the request */
	if ( nvmetcp->phase != NVMETCP_PHASE_READY ) {
		DBGC ( nvmetcp, "capacity deferred\n" );
		nvmetcp->capacity_data = data;
		return 0;
	}

	/* Return capacity */
	block_capacity ( &nvmetcp->data, &nvmetcp->capacity );
	intf_restart ( &nvmetcp->data, 0 );

	return 0;
}

/**
 * Read from or write to NVMe namespace
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Block data interface
 * @v lba		Starting logical block address
 * @v count		Number of blocks to transfer
 * @v buffer		Data buffer
 * @v len		Length of data buffer
 * @v opcode		NVMe command opcode
 * @ret rc		Return status code
 */
static int nvmetcp_block_rw ( struct nvmetcp_session *nvmetcp,
			      struct interface *data,
			      uint64_t lba, unsigned int count,
			      void *buffer, size_t len, uint8_t opcode ) {
	union nvme_command *cmd = &nvmetcp->cmd;
	int rc;

	/* Sanity checks */
	if ( nvmetcp->phase != NVMETCP_PHASE_READY ) {
		DBGC ( nvmetcp, "block command before ready\n" );
		return -EAGAIN;
	}
	if ( len > NVMETCP_MAX_CMD_DATA ) {
		DBGC ( nvmetcp, "oversized block command (%zd bytes)\n", len );
		return -EINVAL;
	}
	if ( nvmetcp->block_data ) {
		DBGC ( nvmetcp, "block command already in progress\n" );
		return -EAGAIN;
	}

	/* Record block command state */
	intf_plug_plug ( &nvmetcp->data, data );
	nvmetcp->block_data = data;
	nvmetcp->block_buffer = buffer;
	nvmetcp->block_len = len;
	nvmetcp->block_writing = ( opcode == NVME_OPCODE_WRITE );

	/* Construct read/write command */
	memset ( cmd, 0, sizeof ( *cmd ) );
	cmd->rw.opcode = opcode;
	cmd->rw.command_id = cpu_to_le16 ( ++nvmetcp->cid );
	cmd->rw.nsid = cpu_to_le32 ( nvmetcp->nsid );
	cmd->rw.slba = cpu_to_le64 ( lba );
	cmd->rw.length = cpu_to_le16 ( count - 1 );

	/* Send command (with in-capsule data for writes) */
	if ( ( rc = nvmetcp_tx_command ( nvmetcp, &nvmetcp->io_socket, cmd,
					 nvmetcp->block_writing ? buffer : NULL,
					 nvmetcp->block_writing ? len : 0,
					 nvmetcp->block_writing ? 0 : len ) ) != 0 ) {
		nvmetcp->block_data = NULL;
		intf_restart ( &nvmetcp->data, rc );
		return rc;
	}

	return 0;
}

/**
 * Read from NVMe namespace
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Block data interface
 * @v lba		Starting logical block address
 * @v count		Number of blocks to transfer
 * @v buffer		Data buffer
 * @v len		Length of data buffer
 * @ret rc		Return status code
 */
static int nvmetcp_block_read ( struct nvmetcp_session *nvmetcp,
				struct interface *data,
				uint64_t lba, unsigned int count,
				void *buffer, size_t len ) {
	return nvmetcp_block_rw ( nvmetcp, data, lba, count, buffer, len,
				  NVME_OPCODE_READ );
}

/**
 * Write to NVMe namespace
 *
 * @v nvmetcp		NVMe/TCP session
 * @v data		Block data interface
 * @v lba		Starting logical block address
 * @v count		Number of blocks to transfer
 * @v buffer		Data buffer
 * @v len		Length of data buffer
 * @ret rc		Return status code
 */
static int nvmetcp_block_write ( struct nvmetcp_session *nvmetcp,
				 struct interface *data,
				 uint64_t lba, unsigned int count,
				 void *buffer, size_t len ) {
	return nvmetcp_block_rw ( nvmetcp, data, lba, count, buffer, len,
				  NVME_OPCODE_WRITE );
}

/**
 * Receive data from socket
 *
 * @v nvmetcp		NVMe/TCP session
 * @v iobuf		I/O buffer
 * @v rx		PDU receive state
 * @v meta		Transfer metadata
 * @ret rc		Return status code
 */
static int nvmetcp_socket_deliver ( struct nvmetcp_session *nvmetcp,
				    struct io_buffer *iobuf,
				    struct nvmetcp_rx *rx,
				    struct xfer_metadata *meta __unused ) {
	size_t len;
	size_t avail;
	int rc = 0;

	DBGC ( nvmetcp, "socket deliver %zd bytes\n", iob_len ( iobuf ) );

	/* Consume the received data */
	while ( iob_len ( iobuf ) ) {
		avail = iob_len ( iobuf );

		if ( rx->hdr_len < rx->hdr_expect ) {
			/* Receive PDU header */
			len = rx->hdr_expect - rx->hdr_len;
			len = ( len < avail ) ? len : avail;
			memcpy ( &rx->hdr[rx->hdr_len], iobuf->data, len );
			rx->hdr_len += len;
			iob_pull ( iobuf, len );
			if ( rx->hdr_len == 8 ) {
				/* Determine PDU-specific header length */
				if ( ( rc = nvmetcp_rx_header ( nvmetcp, rx ) ) != 0 )
					break;
			}
			if ( rx->hdr_len < rx->hdr_expect )
				continue;
			/* Process PDU-specific header */
			if ( ( rc = nvmetcp_rx_pdu ( nvmetcp, rx ) ) != 0 )
				break;
			if ( rx->data_expect == 0 ) {
				/* No data: PDU complete */
				if ( ( rc = nvmetcp_rx_pdu_complete ( nvmetcp, rx ) ) != 0 )
					break;
			}
			continue;
		}

		/* Receive PDU data */
		len = rx->data_expect - rx->data_len;
		len = ( len < avail ) ? len : avail;
		memcpy ( &nvmetcp->cmd_buf[rx->data_len], iobuf->data, len );
		rx->data_len += len;
		nvmetcp->cmd_data_offset += len;
		iob_pull ( iobuf, len );
		if ( rx->data_len < rx->data_expect )
			continue;
		/* Data fully received: PDU complete */
		if ( ( rc = nvmetcp_rx_pdu_complete ( nvmetcp, rx ) ) != 0 )
			break;
	}

	free_iob ( iobuf );
	return rc;
}

/**
 * Receive data from admin queue socket
 *
 * @v nvmetcp		NVMe/TCP session
 * @v iobuf		I/O buffer
 * @v meta		Transfer metadata
 * @ret rc		Return status code
 */
static int nvmetcp_admin_socket_deliver ( struct nvmetcp_session *nvmetcp,
					  struct io_buffer *iobuf,
					  struct xfer_metadata *meta ) {
	return nvmetcp_socket_deliver ( nvmetcp, iobuf, &nvmetcp->rx, meta );
}

/**
 * Receive data from I/O queue socket
 *
 * @v nvmetcp		NVMe/TCP session
 * @v iobuf		I/O buffer
 * @v meta		Transfer metadata
 * @ret rc		Return status code
 */
static int nvmetcp_io_socket_deliver ( struct nvmetcp_session *nvmetcp,
				       struct io_buffer *iobuf,
				       struct xfer_metadata *meta ) {
	return nvmetcp_socket_deliver ( nvmetcp, iobuf, &nvmetcp->rx_io, meta );
}

/**
 * Step the session state machine
 *
 * @v nvmetcp		NVMe/TCP session
 */
static void nvmetcp_step ( struct nvmetcp_session *nvmetcp ) {
	int rc;

	switch ( nvmetcp->phase ) {
	case NVMETCP_PHASE_ICREQ:
		if ( ( rc = nvmetcp_tx_icreq ( nvmetcp,
						  &nvmetcp->socket ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_ICREQ_IO:
		if ( ( rc = nvmetcp_tx_icreq ( nvmetcp,
						  &nvmetcp->io_socket ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_CONNECT_ADMIN:
		if ( ( rc = nvmetcp_tx_connect ( nvmetcp, &nvmetcp->socket,
						      0 ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_PROP_SET:
		if ( ( rc = nvmetcp_tx_prop_set ( nvmetcp ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_AUTH:
		if ( ( rc = nvmetcp_auth_step ( nvmetcp ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_IDENTIFY_CTRL:
		if ( ( rc = nvmetcp_tx_identify ( nvmetcp,
						  NVME_IDENTIFY_CTRL, 0 ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_IDENTIFY_NS:
		if ( ( rc = nvmetcp_tx_identify ( nvmetcp, NVME_IDENTIFY_NS,
						  nvmetcp->nsid ) ) != 0 )
			goto err;
		return;
	case NVMETCP_PHASE_CONNECT_IO:
		if ( ( rc = nvmetcp_tx_connect ( nvmetcp, &nvmetcp->io_socket,
						      1 ) ) != 0 )
			goto err;
		return;
	default:
		return;
	}

 err:
	if ( rc == -EAGAIN ) {
		/* Wait for the TCP window to become available */
		DBGC ( nvmetcp, "waiting for window (phase %d)\n",
		       nvmetcp->phase );
		process_del ( &nvmetcp->process );
		return;
	}
	/* Retry transient allocation failures */
	if ( rc == -ENOMEM )
		return;
	DBGC ( nvmetcp, "could not step (phase %d): %s\n", nvmetcp->phase,
	       strerror ( rc ) );
	nvmetcp_close ( nvmetcp, rc );
}

/**
 * Resume transmission
 *
 * @v nvmetcp		NVMe/TCP session
 */
static void nvmetcp_tx_resume ( struct nvmetcp_session *nvmetcp ) {

	/* Do not resume while a command is in flight: the TCP window may
	 * change (e.g. when the last fragment of a large PDU is
	 * acknowledged) before the target has replied, and resuming
	 * would resend the entire command.
	 */
	if ( nvmetcp->tx_in_flight )
		return;

	DBGC ( nvmetcp, "resume\n" );
	process_add ( &nvmetcp->process );
}

/**
 * Process step
 *
 * @v nvmetcp		NVMe/TCP session
 */
static void nvmetcp_process ( struct nvmetcp_session *nvmetcp ) {

	nvmetcp_step ( nvmetcp );
}

/** NVMe/TCP process descriptor */
static struct process_descriptor nvmetcp_process_desc =
	PROC_DESC ( struct nvmetcp_session, process, nvmetcp_process );

/** NVMe/TCP socket interface operations */
static struct interface_operation nvmetcp_socket_operations[] = {
	INTF_OP ( xfer_deliver, struct nvmetcp_session *,
		  nvmetcp_admin_socket_deliver ),
	INTF_OP ( xfer_window_changed, struct nvmetcp_session *, nvmetcp_tx_resume ),
	INTF_OP ( intf_close, struct nvmetcp_session *, nvmetcp_close ),
};

/** NVMe/TCP socket interface descriptor */
static struct interface_descriptor nvmetcp_socket_desc =
	INTF_DESC ( struct nvmetcp_session, socket, nvmetcp_socket_operations );

/** NVMe/TCP I/O queue socket interface operations */
static struct interface_operation nvmetcp_io_socket_operations[] = {
	INTF_OP ( xfer_deliver, struct nvmetcp_session *,
		  nvmetcp_io_socket_deliver ),
	INTF_OP ( xfer_window_changed, struct nvmetcp_session *, nvmetcp_tx_resume ),
	INTF_OP ( intf_close, struct nvmetcp_session *, nvmetcp_close ),
};

/** NVMe/TCP I/O queue socket interface descriptor */
static struct interface_descriptor nvmetcp_io_socket_desc =
	INTF_DESC ( struct nvmetcp_session, io_socket, nvmetcp_io_socket_operations );

/**
 * Close NVMe/TCP command
 *
 * @v nvmetcp		NVMe/TCP session
 * @v rc		Reason for close
 */
static void nvmetcp_command_close ( struct nvmetcp_session *nvmetcp, int rc ) {

	/* Restart interface */
	intf_restart ( &nvmetcp->data, rc );

	/* Treat unsolicited command closures mid-command as fatal,
	 * because we have no code to handle partially-completed commands.
	 */
	if ( nvmetcp->block_data || nvmetcp->capacity_data ) {
		nvmetcp->block_data = NULL;
		nvmetcp->capacity_data = NULL;
		nvmetcp_close ( nvmetcp, ( ( rc == 0 ) ? -ECANCELED : rc ) );
	}
}

/** NVMe/TCP command completion interface operations */
static struct interface_operation nvmetcp_data_operations[] = {
	INTF_OP ( intf_close, struct nvmetcp_session *, nvmetcp_command_close ),
};

/** NVMe/TCP command completion interface descriptor */
static struct interface_descriptor nvmetcp_data_desc =
	INTF_DESC ( struct nvmetcp_session, data, nvmetcp_data_operations );

/**
 * Get NVMe/TCP EFI device path
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret path		EFI device path, or NULL on error
 */
static EFI_DEVICE_PATH_PROTOCOL *
nvmetcp_describe ( struct nvmetcp_session *nvmetcp ) {

	return efi_uri_path ( nvmetcp->uri );
}

/**
 * Get NVMe/TCP ACPI descriptor
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret desc		ACPI descriptor, or NULL
 */
static struct acpi_descriptor *
nvmetcp_acpi_describe ( struct nvmetcp_session *nvmetcp ) {

	return &nvmetcp->desc;
}

/** NVMe/TCP control interface operations */
static struct interface_operation nvmetcp_control_operations[] = {
	INTF_OP ( block_read_capacity, struct nvmetcp_session *,
		  nvmetcp_block_read_capacity ),
	INTF_OP ( block_read, struct nvmetcp_session *, nvmetcp_block_read ),
	INTF_OP ( block_write, struct nvmetcp_session *, nvmetcp_block_write ),
	INTF_OP ( intf_close, struct nvmetcp_session *, nvmetcp_close ),
	INTF_OP ( acpi_describe, struct nvmetcp_session *,
		  nvmetcp_acpi_describe ),
	EFI_INTF_OP ( efi_describe, struct nvmetcp_session *, nvmetcp_describe ),
};

/** NVMe/TCP control interface descriptor */
static struct interface_descriptor nvmetcp_control_desc =
	INTF_DESC ( struct nvmetcp_session, control, nvmetcp_control_operations );

/**
 * Parse URI secret (query parameter "secret=")
 *
 * @v nvmetcp		NVMe/TCP session
 * @v uri		URI
 * @ret rc		Return status code
 */
static int nvmetcp_parse_secret ( struct nvmetcp_session *nvmetcp,
				  struct uri *uri ) {
	const char *query;
	char *secret;
	char *end;
	size_t len;

	if ( ! uri->equery )
		return 0;

	/* Locate "secret=" parameter */
	query = uri->equery;
	while ( ( secret = strstr ( query, "secret=" ) ) != NULL ) {
		query = secret + 7;
		if ( ( secret == uri->equery ) || ( secret[-1] == '&' ) )
			break;
	}
	if ( ! secret )
		return 0;

	/* Extract value (up to next '&') */
	end = strchr ( secret + 7, '&' );
	len = ( end ? ( ( size_t ) ( end - secret ) - 7 ) :
		( strlen ( secret ) - 7 ) );
	if ( len == 0 )
		return 0;
	nvmetcp->secret = zalloc ( len + 1 );
	if ( ! nvmetcp->secret )
		return -ENOMEM;
	memcpy ( nvmetcp->secret, secret + 7, len );

	return 0;
}

/**
 * Parse root path
 *
 * @v nvmetcp		NVMe/TCP session
 * @v uri		URI
 * @ret rc		Return status code
 */
static int nvmetcp_parse_root_path ( struct nvmetcp_session *nvmetcp,
				     struct uri *uri ) {
	const char *nqn;
	size_t nqn_len;

	/* Target address */
	if ( ! uri->host ) {
		DBGC ( nvmetcp, "no target address supplied in %s\n",
		       uri->opaque ? uri->opaque : "" );
		return -EINVAL_NO_TARGET;
	}
	nvmetcp->target_host = strdup ( uri->host );
	if ( ! nvmetcp->target_host )
		return -ENOMEM;

	/* Target port */
	nvmetcp->target_port = uri_port ( uri, NVMETCP_DEFAULT_PORT );

	/* Subsystem NQN (from URI path, e.g. "/nqn.2014-08.org...") */
	if ( ! uri->path || ( uri->path[0] != '/' ) ) {
		DBGC ( nvmetcp, "no subsystem NQN supplied in %s\n",
		       uri->opaque ? uri->opaque : "" );
		return -EINVAL_NO_SUBSYSTEM_NQN;
	}
	nqn = &uri->path[1];
	nqn_len = strlen ( nqn );
	if ( ( nqn_len == 0 ) || ( nqn_len >= NVMF_NQN_FIELD_LEN ) ) {
		DBGC ( nvmetcp, "invalid subsystem NQN in %s\n", uri->opaque );
		return -EINVAL_NO_SUBSYSTEM_NQN;
	}
	nvmetcp->subsystem_nqn = strdup ( nqn );
	if ( ! nvmetcp->subsystem_nqn )
		return -ENOMEM;

	/* Authentication secret */
	return nvmetcp_parse_secret ( nvmetcp, uri );
}

/** NVMe host NQN setting (overrides the UUID-derived default) */
static struct setting hostnqn_setting __setting ( SETTING_HOST_EXTRA,
						  hostnqn ) = {
	.name = "hostnqn",
	.description = "NVMe host NQN",
	.type = &setting_type_string,
};

/**
 * Construct host NQN
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 *
 * Prefer the explicitly configured host NQN (e.g. injected by the
 * boot server per MAC address), falling back to the UUID-derived
 * default so plain nvme:// URIs stay self-contained.
 */
static int nvmetcp_set_host_nqn ( struct nvmetcp_session *nvmetcp ) {
	union uuid uuid;
	char *nqn;
	size_t len;

	nqn = NULL;
	fetch_string_setting_copy ( NULL, &hostnqn_setting, &nqn );
	if ( nqn ) {
		nvmetcp->host_nqn = nqn;
		return 0;
	}

	len = ( sizeof ( NVMETCP_DEFAULT_HOST_NQN ) - 1 +
		sizeof ( uuid ) * 2 );
	nqn = zalloc ( len );
	if ( ! nqn )
		return -ENOMEM;

	if ( fetch_uuid_setting ( NULL, &uuid_setting, &uuid ) != 0 ) {
		/* No system UUID: use a fixed suffix */
		snprintf ( nqn, len, "%sipxe", NVMETCP_DEFAULT_HOST_NQN );
	} else {
		snprintf ( nqn, len, "%s%s", NVMETCP_DEFAULT_HOST_NQN,
			   uuid_ntoa ( &uuid ) );
	}
	nvmetcp->host_nqn = nqn;
	return 0;
}

/**
 * Open NVMe/TCP socket
 *
 * @v nvmetcp		NVMe/TCP session
 * @v socket		Socket interface
 * @v rx		PDU receive state
 * @v phase		Phase to enter once connected
 * @ret rc		Return status code
 */
static int nvmetcp_open_socket ( struct nvmetcp_session *nvmetcp,
				 struct interface *socket,
				 struct nvmetcp_rx *rx,
				 unsigned int phase ) {
	struct sockaddr_tcpip target;
	int rc;

	/* Open socket */
	memset ( &target, 0, sizeof ( target ) );
	target.st_port = htons ( nvmetcp->target_port );
	if ( ( rc = xfer_open_named_socket ( socket, SOCK_STREAM,
					     ( struct sockaddr * ) &target,
					     nvmetcp->target_host, NULL ) ) != 0 ) {
		DBGC ( nvmetcp, "could not open socket: %s\n", strerror ( rc ) );
		return rc;
	}

	/* Enter requested phase */
	nvmetcp->phase = phase;
	nvmetcp_rx_reset ( rx );
	nvmetcp_tx_resume ( nvmetcp );

	return 0;
}

/**
 * Open NVMe/TCP session
 *
 * @v parent		Parent interface
 * @v uri		URI
 * @ret rc		Return status code
 */
static int nvmetcp_open ( struct interface *parent, struct uri *uri ) {
	struct nvmetcp_session *nvmetcp;
	int rc;

	/* Sanity check */
	if ( ! uri->path ) {
		rc = -EINVAL_NO_ROOT_PATH;
		goto err_sanity_uri;
	}

	/* Allocate and initialise structure */
	nvmetcp = zalloc ( sizeof ( *nvmetcp ) );
	if ( ! nvmetcp ) {
		rc = -ENOMEM;
		goto err_zalloc;
	}
	ref_init ( &nvmetcp->refcnt, nvmetcp_free );
	intf_init ( &nvmetcp->control, &nvmetcp_control_desc, &nvmetcp->refcnt );
	intf_init ( &nvmetcp->data, &nvmetcp_data_desc, &nvmetcp->refcnt );
	intf_init ( &nvmetcp->socket, &nvmetcp_socket_desc, &nvmetcp->refcnt );
	intf_init ( &nvmetcp->io_socket, &nvmetcp_io_socket_desc,
		    &nvmetcp->refcnt );
	process_init_stopped ( &nvmetcp->process, &nvmetcp_process_desc,
			       &nvmetcp->refcnt );
	acpi_init ( &nvmetcp->desc, &nbct_model, &nvmetcp->refcnt );

	/* Identify the first namespace */
	nvmetcp->nsid = 1;

	/* Record URI for device path generation */
	nvmetcp->uri = uri_get ( uri );

	/* Parse root path */
	if ( ( rc = nvmetcp_parse_root_path ( nvmetcp, uri ) ) != 0 )
		goto err_parse_root_path;

	/* Construct host NQN */
	if ( ( rc = nvmetcp_set_host_nqn ( nvmetcp ) ) != 0 )
		goto err_set_host_nqn;

	DBGC ( nvmetcp, "target %s:%d subsystem %s host %s\n",
	       nvmetcp->target_host, nvmetcp->target_port,
	       nvmetcp->subsystem_nqn, nvmetcp->host_nqn );

	/* Open admin queue socket */
	if ( ( rc = nvmetcp_open_socket ( nvmetcp, &nvmetcp->socket,
					  &nvmetcp->rx,
					  NVMETCP_PHASE_ICREQ ) ) != 0 )
		goto err_open_socket;

	/* Attach to parent interface and return */
	intf_plug_plug ( &nvmetcp->control, parent );
	ref_put ( &nvmetcp->refcnt );
	return 0;

 err_open_socket:
 err_set_host_nqn:
 err_parse_root_path:
	nvmetcp_close ( nvmetcp, rc );
	ref_put ( &nvmetcp->refcnt );
 err_zalloc:
 err_sanity_uri:
	return rc;
}

/** NVMe/TCP URI opener */
struct uri_opener nvmetcp_uri_opener __uri_opener = {
	.scheme = "nvme",
	.open = nvmetcp_open,
};
