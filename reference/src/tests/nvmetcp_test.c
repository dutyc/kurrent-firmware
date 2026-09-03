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
 * NVMe-over-TCP protocol self-tests: PDU structure layout and
 * Identify Namespace data parsing.
 */

FILE_LICENCE ( GPL2_ONLY );

/* Forcibly enable assertions */
#undef NDEBUG

/* Identify errors as coming from this file */
#undef ERRFILE
#define ERRFILE ERRFILE_nvmetcp_test

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#include <ipxe/test.h>
#include <ipxe/nvmetcp.h>

/* Forward declaration */
struct self_test nvmetcp_test __self_test;

/**
 * Report a valid Identify Namespace data parsing test
 *
 * @v nsze		Namespace size (logical blocks)
 * @v flbas		FLBAS value
 * @v lbads		LBA data size exponent (LBAF[fmt].ds)
 * @v blksize		Expected block size
 * @v max_count		Expected maximum transfer count
 */
static void identify_ns_ok ( uint64_t nsze, uint8_t flbas, uint8_t lbads,
			     size_t blksize, unsigned int max_count ) {
	static uint8_t data[NVME_IDENTIFY_DATA_SIZE];
	struct block_device_capacity capacity;
	unsigned int i;

	/* Construct Identify Namespace data */
	memset ( data, 0, sizeof ( data ) );
	/* NSZE (little-endian u64 at offset 0) */
	for ( i = 0; i < sizeof ( nsze ); i++ )
		data[i] = ( nsze >> ( 8 * i ) );
	/* FLBAS (format index in low nibble, at offset 26) */
	data[26] = flbas;
	/* LBAF[fmt].ds (at offset 128 + fmt*4 + 2) */
	data[128 + ( ( flbas & 0x0f ) * 4 ) + 2] = lbads;

	/* Parse and validate */
	ok ( nvmetcp_identify_ns ( data, &capacity ) == 0 );
	ok ( capacity.blocks == nsze );
	ok ( capacity.blksize == blksize );
	ok ( capacity.max_count == max_count );
}

/**
 * Report an invalid Identify Namespace data parsing test
 *
 * @v nsze		Namespace size (logical blocks)
 * @v flbas		FLBAS value
 * @v lbads		LBA data size exponent (LBAF[fmt].ds)
 */
static void identify_ns_fail ( uint64_t nsze, uint8_t flbas, uint8_t lbads ) {
	static uint8_t data[NVME_IDENTIFY_DATA_SIZE];
	struct block_device_capacity capacity;
	unsigned int i;

	/* Construct Identify Namespace data */
	memset ( data, 0, sizeof ( data ) );
	for ( i = 0; i < sizeof ( nsze ); i++ )
		data[i] = ( nsze >> ( 8 * i ) );
	data[26] = flbas;
	data[128 + ( ( flbas & 0x0f ) * 4 ) + 2] = lbads;

	/* Parsing should fail */
	ok ( nvmetcp_identify_ns ( data, &capacity ) != 0 );
}

/**
 * Report an NVMe/TCP structure layout test
 */
static void nvmetcp_layout_test ( void ) {

	/* PDU common header */
	ok ( sizeof ( struct nvmetcp_pdu_header ) == 8 );

	/* ICReq and ICResp PDUs (128 bytes on the wire) */
	ok ( sizeof ( struct nvmetcp_icreq ) == 128 );
	ok ( sizeof ( struct nvmetcp_icresp ) == 128 );
	ok ( offsetof ( struct nvmetcp_icreq, pfv ) == 8 );

	/* Command and response PDUs */
	ok ( sizeof ( struct nvmetcp_cmd_pdu ) == 72 );
	ok ( offsetof ( struct nvmetcp_cmd_pdu, cmd ) == 8 );
	ok ( sizeof ( struct nvmetcp_rsp_pdu ) == 24 );
	ok ( offsetof ( struct nvmetcp_rsp_pdu, cqe ) == 8 );

	/* Data and R2T PDUs */
	ok ( sizeof ( struct nvmetcp_data_pdu ) == 24 );
	ok ( offsetof ( struct nvmetcp_data_pdu, data_offset ) == 12 );
	ok ( offsetof ( struct nvmetcp_data_pdu, data_length ) == 16 );
	ok ( sizeof ( struct nvmetcp_r2t_pdu ) == 24 );
	ok ( offsetof ( struct nvmetcp_r2t_pdu, r2t_offset ) == 12 );
	ok ( offsetof ( struct nvmetcp_r2t_pdu, r2t_length ) == 16 );

	/* NVMe commands are all 64 bytes */
	ok ( sizeof ( struct nvme_common_command ) == 64 );
	ok ( sizeof ( struct nvme_identify ) == 64 );
	ok ( offsetof ( struct nvme_identify, cns ) == 40 );
	ok ( sizeof ( struct nvme_rw_command ) == 64 );
	ok ( sizeof ( struct nvmf_connect_command ) == 64 );
	ok ( offsetof ( struct nvmf_connect_command, fctype ) == 4 );
	ok ( offsetof ( struct nvmf_connect_command, qid ) == 42 );
	ok ( offsetof ( struct nvmf_connect_command, kato ) == 48 );
	ok ( sizeof ( struct nvmf_auth_common_command ) == 64 );
	ok ( sizeof ( struct nvme_sgl_desc ) == 16 );
	ok ( sizeof ( struct nvme_completion ) == 16 );

	/* Connect data (1024 bytes) */
	ok ( sizeof ( struct nvmf_connect_data ) == 1024 );
	ok ( offsetof ( struct nvmf_connect_data, subsysnqn ) == 256 );
	ok ( offsetof ( struct nvmf_connect_data, hostnqn ) == 512 );

	/* Authentication data structures */
	ok ( sizeof ( union nvmf_auth_protocol ) == 64 );
	ok ( sizeof ( struct nvmf_auth_dhchap_negotiate_data ) == 8 );
	ok ( sizeof ( struct nvmf_auth_dhchap_challenge_data ) == 16 );
	ok ( offsetof ( struct nvmf_auth_dhchap_challenge_data, cval ) == 16 );
	ok ( sizeof ( struct nvmf_auth_dhchap_reply_data ) == 16 );
	ok ( offsetof ( struct nvmf_auth_dhchap_reply_data, rval ) == 16 );
	ok ( sizeof ( struct nvmf_auth_dhchap_success1_data ) == 16 );
	ok ( sizeof ( struct nvmf_auth_dhchap_success2_data ) == 16 );
	ok ( sizeof ( struct nvmf_auth_dhchap_failure_data ) == 8 );
}

/**
 * Report an NVMe/TCP protocol constant test
 */
static void nvmetcp_constant_test ( void ) {

	/* PDU types (TP 8000) */
	ok ( NVMETCP_PDU_ICREQ == 0x00 );
	ok ( NVMETCP_PDU_ICRESP == 0x01 );
	ok ( NVMETCP_PDU_H2CTERM == 0x02 );
	ok ( NVMETCP_PDU_C2HTERM == 0x03 );
	ok ( NVMETCP_PDU_COMMAND == 0x04 );
	ok ( NVMETCP_PDU_RESPONSE == 0x05 );
	ok ( NVMETCP_PDU_H2CDATA == 0x06 );
	ok ( NVMETCP_PDU_C2HDATA == 0x07 );
	ok ( NVMETCP_PDU_R2T == 0x09 );

	/* Protocol parameters */
	ok ( NVMETCP_PFV == 0x0000 );
	ok ( NVMETCP_DEFAULT_PORT == 4420 );
	ok ( NVMETCP_MAX_CMD_DATA == 4096 );

	/* NVMe over Fabrics commands */
	ok ( NVMF_OPCODE == 0x7f );
	ok ( NVMF_FCTYPE_CONNECT == 0x01 );
	ok ( NVMF_FCTYPE_AUTH_SEND == 0x05 );
	ok ( NVMF_FCTYPE_AUTH_RECEIVE == 0x06 );
	ok ( NVMF_NQN_FIELD_LEN == 256 );

	/* NVMe command opcodes */
	ok ( NVME_OPCODE_WRITE == 0x01 );
	ok ( NVME_OPCODE_READ == 0x02 );
	ok ( NVME_OPCODE_IDENTIFY == 0x06 );
	ok ( NVME_IDENTIFY_NS == 0x00 );
	ok ( NVME_IDENTIFY_CTRL == 0x01 );
	ok ( NVME_IDENTIFY_DATA_SIZE == 4096 );
	ok ( NVME_CMD_SGL_METABUF == ( 1 << 6 ) );

	/* DH-HMAC-CHAP authentication */
	ok ( NVME_AUTH_DHCHAP_AUTH_ID == 0x01 );
	ok ( NVME_AUTH_HASH_SHA256 == 0x01 );
	ok ( NVME_AUTH_HASH_SHA384 == 0x02 );
	ok ( NVME_AUTH_HASH_SHA512 == 0x03 );
	ok ( NVME_AUTH_DHGROUP_2048 == 0x01 );
	ok ( NVME_AUTH_DHGROUP_8192 == 0x05 );
	ok ( NVME_AUTH_MAX_DIGEST_SIZE == 64 );
	ok ( NVME_AUTH_MAX_DH_SIZE == 512 );
}

/**
 * Report an Identify Namespace data parsing test
 */
static void nvmetcp_identify_ns_test ( void ) {

	/* 512-byte blocks (LBAF[3].ds = 9): 4096 / 512 = 8 blocks/command */
	identify_ns_ok ( 1234, 0x03, 9, 512, 8 );
	/* 4096-byte blocks (LBAF[0].ds = 12): 4096 / 4096 = 1 block/command */
	identify_ns_ok ( 4096, 0x00, 12, 4096, 1 );
	/* 16-byte blocks (LBAF[0].ds = 4): 4096 / 16 = 256 blocks/command */
	identify_ns_ok ( 0x1000000000000000ULL, 0x0f, 4, 16, 256 );
	/* 2^31-byte blocks: max_count rounds down to zero */
	identify_ns_ok ( 2, 0x01, 31, ( 1U << 31 ), 0 );

	/* Zero block size (LBAF[0].ds = 0) is invalid */
	identify_ns_fail ( 100, 0x00, 0 );
	/* Block size exponent above 31 is invalid */
	identify_ns_fail ( 100, 0x00, 32 );
	identify_ns_fail ( 100, 0x01, 255 );
}

/**
 * Report an authentication phase completion test
 */
static void nvmetcp_auth_try_complete_test ( void ) {
	struct nvmetcp_session nvmetcp;
	struct nvmetcp_auth *auth = &nvmetcp.auth;

	/* Neither the success1 data nor the AuthReceive completion
	 * received: no phase advancement */
	memset ( &nvmetcp, 0, sizeof ( nvmetcp ) );
	nvmetcp.phase = NVMETCP_PHASE_AUTH;
	auth->completed = 0;
	auth->rx_complete = 0;
	nvmetcp_auth_try_complete ( &nvmetcp );
	ok ( nvmetcp.phase == NVMETCP_PHASE_AUTH );

	/* Success1 data validated but the AuthReceive completion still
	 * pending: must not advance (the Property Set phase would be
	 * skipped, and the subsequent Identify would be rejected) */
	auth->completed = 1;
	nvmetcp_auth_try_complete ( &nvmetcp );
	ok ( nvmetcp.phase == NVMETCP_PHASE_AUTH );

	/* AuthReceive completion received but success1 data still
	 * pending: likewise */
	auth->completed = 0;
	auth->rx_complete = 1;
	nvmetcp_auth_try_complete ( &nvmetcp );
	ok ( nvmetcp.phase == NVMETCP_PHASE_AUTH );

	/* Both received (in either order): advance to the Property Set
	 * phase */
	auth->completed = 1;
	nvmetcp_auth_try_complete ( &nvmetcp );
	ok ( nvmetcp.phase == NVMETCP_PHASE_PROP_SET );

	/* Idempotent: repeated calls keep the advanced phase */
	nvmetcp_auth_try_complete ( &nvmetcp );
	ok ( nvmetcp.phase == NVMETCP_PHASE_PROP_SET );
}

/**
 * Report an AuthReceive completion identification test
 */
static void nvmetcp_auth_rx_complete_test ( void ) {
	struct nvmetcp_session nvmetcp;
	struct nvmetcp_auth *auth = &nvmetcp.auth;

	/* A Reply completion (different command id) processed after the
	 * AuthReceive has been sent must not be mistaken for the final
	 * AuthReceive completion */
	memset ( &nvmetcp, 0, sizeof ( nvmetcp ) );
	nvmetcp.phase = NVMETCP_PHASE_AUTH;
	auth->step = NVMETCP_AUTH_STEP_SUCCESS1;
	auth->rx_cid = 6;
	nvmetcp.cqe.command_id = cpu_to_le16 ( 4 );
	ok ( nvmetcp_auth_rx_complete ( &nvmetcp ) == 0 );
	ok ( auth->rx_complete == 0 );

	/* The matching command id completes the phase */
	nvmetcp.cqe.command_id = cpu_to_le16 ( auth->rx_cid );
	ok ( nvmetcp_auth_rx_complete ( &nvmetcp ) == 0 );
	ok ( auth->rx_complete == 1 );

	/* Data-first ordering: a completion processed in the START step
	 * with the matching id still completes the phase */
	memset ( &nvmetcp, 0, sizeof ( nvmetcp ) );
	nvmetcp.phase = NVMETCP_PHASE_AUTH;
	auth->step = NVMETCP_AUTH_STEP_START;
	auth->rx_cid = 6;
	nvmetcp.cqe.command_id = cpu_to_le16 ( 6 );
	ok ( nvmetcp_auth_rx_complete ( &nvmetcp ) == 0 );
	ok ( auth->rx_complete == 1 );
}

/**
 * Report an authentication step guard test
 */
static void nvmetcp_auth_step_test ( void ) {
	struct nvmetcp_session nvmetcp;
	struct nvmetcp_auth *auth = &nvmetcp.auth;

	/* Once the success1 data has been validated, the START step must
	 * not re-send the Negotiate: the session is only awaiting the
	 * final AuthReceive completion */
	memset ( &nvmetcp, 0, sizeof ( nvmetcp ) );
	nvmetcp.phase = NVMETCP_PHASE_AUTH;
	auth->step = NVMETCP_AUTH_STEP_START;
	auth->completed = 1;
	ok ( nvmetcp_auth_step ( &nvmetcp ) == 0 );
	ok ( auth->step == NVMETCP_AUTH_STEP_START );
}

/**
 * Report an NVMe/TCP self-test result
 */
static void nvmetcp_test_exec ( void ) {

	/* PDU structure layout */
	nvmetcp_layout_test ();

	/* Protocol constants */
	nvmetcp_constant_test ();

	/* Identify Namespace data parsing */
	nvmetcp_identify_ns_test ();

	/* Authentication state machine */
	nvmetcp_auth_try_complete_test ();
	nvmetcp_auth_rx_complete_test ();
	nvmetcp_auth_step_test ();
}

/** NVMe/TCP self-test */
struct self_test nvmetcp_test __self_test = {
	.name = "nvmetcp",
	.exec = nvmetcp_test_exec,
};
