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
 * Protocol definitions derived from the Linux kernel NVMe-over-TCP
 * implementation (drivers/nvme/host/tcp.c and include/linux/nvme-tcp.h,
 * GPL-2.0) and from the NVM Express TCP Transport specification
 * (TP 8000) and NVM Express Base specification 2.x.
 */

FILE_LICENCE ( GPL2_ONLY );

#ifndef _IPXE_NVMETCP_H
#define _IPXE_NVMETCP_H

#include <stdint.h>
#include <errno.h>
#include <byteswap.h>
#include <ipxe/refcnt.h>
#include <ipxe/interface.h>
#include <ipxe/process.h>
#include <ipxe/blockdev.h>
#include <ipxe/acpi.h>

/** Default NVMe/TCP port */
#define NVMETCP_DEFAULT_PORT 4420

/** NVMe over Fabrics command opcode */
#define NVMF_OPCODE 0x7f

/** NVMe over Fabrics command types (fctype) */
#define NVMF_FCTYPE_PROPERTY_SET 0x00
#define NVMF_FCTYPE_CONNECT 0x01
#define NVMF_FCTYPE_PROPERTY_GET 0x04
#define NVMF_FCTYPE_AUTH_SEND 0x05
#define NVMF_FCTYPE_AUTH_RECEIVE 0x06

/** NVMe admin command opcodes */
#define NVME_OPCODE_FLUSH 0x00
#define NVME_OPCODE_WRITE 0x01
#define NVME_OPCODE_READ 0x02
#define NVME_OPCODE_IDENTIFY 0x06
#define NVME_OPCODE_GET_FEATURES 0x0a

/** Identify CNS values */
#define NVME_IDENTIFY_NS 0x00
#define NVME_IDENTIFY_CTRL 0x01

/** Identify data size */
#define NVME_IDENTIFY_DATA_SIZE 4096

/** NQN field length (NVMe over Fabrics) */
#define NVMF_NQN_FIELD_LEN 256

/** Connect response authentication-required flags (result field) */
#define NVMF_CONNECT_AUTHREQ_ATR ( 1U << 17 )
#define NVMF_CONNECT_AUTHREQ_ASCR ( 1U << 18 )

/** Authentication required status code (NVMe base spec) */
#define NVME_SC_AUTH_REQUIRED 0x0c

/** NVMe/TCP PDU types (TP 8000) */
#define NVMETCP_PDU_ICREQ 0x00
#define NVMETCP_PDU_ICRESP 0x01
#define NVMETCP_PDU_H2CTERM 0x02
#define NVMETCP_PDU_C2HTERM 0x03
#define NVMETCP_PDU_COMMAND 0x04
#define NVMETCP_PDU_RESPONSE 0x05
#define NVMETCP_PDU_H2CDATA 0x06
#define NVMETCP_PDU_C2HDATA 0x07
#define NVMETCP_PDU_R2T 0x09

/** NVMe/TCP PDU flags */
#define NVMETCP_F_HDGST ( 1 << 0 )
#define NVMETCP_F_DDGST ( 1 << 1 )
#define NVMETCP_F_DATA_LAST ( 1 << 2 )
#define NVMETCP_F_DATA_SUCCESS ( 1 << 3 )

/** NVMe/TCP protocol version (ICReq/ICResp pfv field) */
#define NVMETCP_PFV 0x0000

/** NVMe/TCP digest negotiation bits (ICReq/ICResp digest field) */
#define NVMETCP_DIGEST_HDR ( 1 << 0 )
#define NVMETCP_DIGEST_DATA ( 1 << 1 )

/** SGL descriptor types (upper nibble) */
#define NVME_SGL_FMT_DATA_DESC 0x00
#define NVME_SGL_FMT_SEG_DESC 0x02
#define NVME_SGL_FMT_LAST_SEG_DESC 0x03
#define NVME_KEY_SGL_FMT_DATA_DESC 0x04
#define NVME_TRANSPORT_SGL_DATA_DESC 0x05

/** SGL descriptor formats (lower nibble) */
#define NVME_SGL_FMT_ADDRESS 0x00
#define NVME_SGL_FMT_OFFSET 0x01
#define NVME_SGL_FMT_TRANSPORT_A 0x02

/** Command flags: use SGL for this transfer */
#define NVME_CMD_SGL_METABUF ( 1 << 6 )

/** NVMe/TCP PDU common header */
struct nvmetcp_pdu_header {
	/** PDU type */
	uint8_t type;
	/** PDU flags */
	uint8_t flags;
	/** PDU header length */
	uint8_t hlen;
	/** PDU data offset */
	uint8_t pdo;
	/** PDU wire byte length (little-endian) */
	uint32_t plen;
} __attribute__ (( packed ));

/** NVMe/TCP ICReq PDU (128 bytes on the wire) */
struct nvmetcp_icreq {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** Protocol version format (little-endian) */
	uint16_t pfv;
	/** Host PDU data alignment */
	uint8_t hpda;
	/** Digest types enabled */
	uint8_t digest;
	/** Maximum R2Ts per request supported (little-endian) */
	uint32_t maxr2t;
	/** Reserved */
	uint8_t rsvd[112];
} __attribute__ (( packed ));

/** NVMe/TCP ICResp PDU (128 bytes on the wire) */
struct nvmetcp_icresp {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** Protocol version format (little-endian) */
	uint16_t pfv;
	/** Controller PDU data alignment */
	uint8_t cpda;
	/** Digest types enabled */
	uint8_t digest;
	/** Maximum data capsules per R2T supported (little-endian) */
	uint32_t maxdata;
	/** Reserved */
	uint8_t rsvd[112];
} __attribute__ (( packed ));

/** SGL descriptor */
struct nvme_sgl_desc {
	/** Address (or in-capsule data offset) */
	uint64_t addr;
	/** Length */
	uint32_t length;
	/** Reserved */
	uint8_t rsvd[3];
	/** Type */
	uint8_t type;
} __attribute__ (( packed ));

/** NVMe command data pointer */
union nvme_data_ptr {
	/** PRP entries */
	struct {
		/** PRP1 */
		uint64_t prp1;
		/** PRP2 */
		uint64_t prp2;
	};
	/** SGL descriptor */
	struct nvme_sgl_desc sgl;
} __attribute__ (( packed ));

/** NVMe common command (first 40 bytes of any 64-byte command) */
struct nvme_common_command {
	/** Opcode */
	uint8_t opcode;
	/** Flags (FUSE / PSDT) */
	uint8_t flags;
	/** Command identifier */
	uint16_t command_id;
	/** Namespace identifier */
	uint32_t nsid;
	/** CDW2..CDW3 */
	uint32_t cdw2[2];
	/** Metadata pointer */
	uint64_t metadata;
	/** Data pointer */
	union nvme_data_ptr dptr;
	/** CDW10..CDW15 */
	uint32_t cdw10;
	uint32_t cdw11;
	uint32_t cdw12;
	uint32_t cdw13;
	uint32_t cdw14;
	uint32_t cdw15;
} __attribute__ (( packed ));

/** NVMe identify command */
struct nvme_identify {
	/** Opcode */
	uint8_t opcode;
	/** Flags */
	uint8_t flags;
	/** Command identifier */
	uint16_t command_id;
	/** Namespace identifier */
	uint32_t nsid;
	/** Reserved */
	uint64_t rsvd2[2];
	/** Data pointer */
	union nvme_data_ptr dptr;
	/** Controller or namespace structure to retrieve (CNS) */
	uint8_t cns;
	/** Reserved */
	uint8_t rsvd3;
	/** Controller identifier */
	uint16_t ctrlid;
	/** Controller namespace specific identifier */
	uint16_t cnssid;
	/** Reserved */
	uint8_t rsvd11;
	/** Command set identifier */
	uint8_t csi;
	/** Reserved */
	uint32_t rsvd12[4];
} __attribute__ (( packed ));

/** NVMe read/write command */
struct nvme_rw_command {
	/** Opcode */
	uint8_t opcode;
	/** Flags */
	uint8_t flags;
	/** Command identifier */
	uint16_t command_id;
	/** Namespace identifier */
	uint32_t nsid;
	/** CDW2..CDW3 */
	uint32_t cdw2;
	uint32_t cdw3;
	/** Metadata pointer */
	uint64_t metadata;
	/** Data pointer */
	union nvme_data_ptr dptr;
	/** Starting LBA */
	uint64_t slba;
	/** Length (number of logical blocks minus one) */
	uint16_t length;
	/** Control */
	uint16_t control;
	/** DSM management */
	uint32_t dsmgmt;
	/** Reference tag */
	uint32_t reftag;
	/** Application tag */
	uint16_t lbat;
	/** Application tag mask */
	uint16_t lbatm;
} __attribute__ (( packed ));

/** NVMe completion queue entry */
struct nvme_completion {
	/** Command-specific result */
	union {
		/** 16-bit result */
		uint16_t u16;
		/** 32-bit result */
		uint32_t u32;
		/** 64-bit result */
		uint64_t u64;
	} result;
	/** Submission queue head pointer */
	uint16_t sq_head;
	/** Submission queue identifier */
	uint16_t sq_id;
	/** Command identifier */
	uint16_t command_id;
	/** Status field */
	uint16_t status;
} __attribute__ (( packed ));

/** NVMe-over-Fabrics connect command */
struct nvmf_connect_command {
	/** Opcode */
	uint8_t opcode;
	/** Reserved */
	uint8_t resv1;
	/** Command identifier */
	uint16_t command_id;
	/** Fabric command type */
	uint8_t fctype;
	/** Reserved */
	uint8_t resv2[19];
	/** Data pointer */
	union nvme_data_ptr dptr;
	/** Record format */
	uint16_t recfmt;
	/** Queue identifier */
	uint16_t qid;
	/** Submission queue size */
	uint16_t sqsize;
	/** Connect attributes */
	uint8_t cattr;
	/** Reserved */
	uint8_t resv3;
	/** Keep-alive timeout (little-endian) */
	uint32_t kato;
	/** Reserved */
	uint8_t resv4[12];
} __attribute__ (( packed ));

/** NVMe controller configuration register */
#define NVME_REG_CC 0x14

/** Controller configuration register fields */
#define NVME_CC_ENABLE ( 1 << 0 )
#define NVME_CC_IOSQES_SHIFT 16
#define NVME_CC_IOCQES_SHIFT 20

/** I/O queue entry sizes (as a power of two) */
#define NVME_NVM_IOSQES 6
#define NVME_NVM_IOCQES 4

/** NVMe-over-Fabrics property set command */
struct nvmf_property_set_command {
	/** Opcode */
	uint8_t opcode;
	/** Reserved */
	uint8_t resv1;
	/** Command identifier */
	uint16_t command_id;
	/** Fabric command type */
	uint8_t fctype;
	/** Reserved */
	uint8_t resv2[35];
	/** Attribute */
	uint8_t attrib;
	/** Reserved */
	uint8_t resv3[3];
	/** Register offset */
	uint32_t offset;
	/** Value */
	uint64_t value;
	/** Reserved */
	uint8_t resv4[8];
} __attribute__ (( packed ));

/** NVMe-over-Fabrics authentication command (common) */
struct nvmf_auth_common_command {
	/** Opcode */
	uint8_t opcode;
	/** Reserved */
	uint8_t resv1;
	/** Command identifier */
	uint16_t command_id;
	/** Fabric command type */
	uint8_t fctype;
	/** Reserved */
	uint8_t resv2[19];
	/** Data pointer */
	union nvme_data_ptr dptr;
	/** Reserved */
	uint8_t resv3;
	/** SPSP0 */
	uint8_t spsp0;
	/** SPSP1 */
	uint8_t spsp1;
	/** Security protocol */
	uint8_t secp;
	/** Allocation length / transfer length (little-endian) */
	uint32_t al_tl;
	/** Reserved */
	uint8_t resv4[16];
} __attribute__ (( packed ));

/** NVMe command */
union nvme_command {
	/** Common command */
	struct nvme_common_command common;
	/** Identify command */
	struct nvme_identify identify;
	/** Read/write command */
	struct nvme_rw_command rw;
	/** Connect command */
	struct nvmf_connect_command connect;
	/** Property set command */
	struct nvmf_property_set_command prop_set;
	/** Auth send command */
	struct nvmf_auth_common_command auth;
} __attribute__ (( packed ));

/** NVMe/TCP command (request) PDU */
struct nvmetcp_cmd_pdu {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** NVMe command */
	union nvme_command cmd;
} __attribute__ (( packed ));

/** NVMe/TCP response PDU */
struct nvmetcp_rsp_pdu {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** Completion queue entry */
	struct nvme_completion cqe;
} __attribute__ (( packed ));

/** NVMe/TCP data PDU (C2HData / H2CData) */
struct nvmetcp_data_pdu {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** Command identifier */
	uint16_t command_id;
	/** Transfer tag */
	uint16_t ttag;
	/** Data offset */
	uint32_t data_offset;
	/** Data length */
	uint32_t data_length;
	/** Reserved */
	uint8_t rsvd[4];
} __attribute__ (( packed ));

/** NVMe/TCP R2T PDU */
struct nvmetcp_r2t_pdu {
	/** PDU header */
	struct nvmetcp_pdu_header hdr;
	/** Command identifier */
	uint16_t command_id;
	/** Transfer tag */
	uint16_t ttag;
	/** R2T offset */
	uint32_t r2t_offset;
	/** R2T length */
	uint32_t r2t_length;
	/** Reserved */
	uint8_t rsvd[4];
} __attribute__ (( packed ));

/** NVMe-over-Fabrics connect data (1024 bytes) */
struct nvmf_connect_data {
	/** Host identifier (UUID) */
	uint8_t hostid[16];
	/** Controller identifier */
	uint16_t cntlid;
	/** Reserved */
	uint8_t resv4[238];
	/** Subsystem NQN */
	char subsysnqn[NVMF_NQN_FIELD_LEN];
	/** Host NQN */
	char hostnqn[NVMF_NQN_FIELD_LEN];
	/** Reserved */
	uint8_t resv5[256];
} __attribute__ (( packed ));

/** DH-HMAC-CHAP authentication protocol descriptor */
struct nvmf_auth_dhchap_protocol_descriptor {
	/** Authentication identifier */
	uint8_t authid;
	/** Reserved */
	uint8_t rsvd;
	/** Hash algorithm list length */
	uint8_t halen;
	/** DH group list length */
	uint8_t dhlen;
	/** Hash algorithm / DH group identifier list */
	uint8_t idlist[60];
} __attribute__ (( packed ));

/** DH-HMAC-CHAP authentication protocol */
union nvmf_auth_protocol {
	/** DH-HMAC-CHAP protocol descriptor */
	struct nvmf_auth_dhchap_protocol_descriptor dhchap;
} __attribute__ (( packed ));

/** DH-HMAC-CHAP negotiate data */
struct nvmf_auth_dhchap_negotiate_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd;
	/** Transaction identifier */
	uint16_t t_id;
	/** Security capabilities */
	uint8_t sc_c;
	/** Number of authentication protocols */
	uint8_t napd;
	/** Authentication protocol */
	union nvmf_auth_protocol auth_protocol[];
} __attribute__ (( packed ));

/** DH-HMAC-CHAP challenge data */
struct nvmf_auth_dhchap_challenge_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd1;
	/** Transaction identifier */
	uint16_t t_id;
	/** Hash length */
	uint8_t hl;
	/** Reserved */
	uint8_t rsvd2;
	/** Hash algorithm identifier */
	uint8_t hashid;
	/** DH group identifier */
	uint8_t dhgid;
	/** DH value length */
	uint16_t dhvlen;
	/** Sequence number */
	uint32_t seqnum;
	/** Challenge value (hl bytes) */
	uint8_t cval[];
	/* Followed by dhvlen bytes of DH value */
} __attribute__ (( packed ));

/** DH-HMAC-CHAP reply data */
struct nvmf_auth_dhchap_reply_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd1;
	/** Transaction identifier */
	uint16_t t_id;
	/** Hash length */
	uint8_t hl;
	/** Reserved */
	uint8_t rsvd2;
	/** Challenge value valid */
	uint8_t cvalid;
	/** Reserved */
	uint8_t rsvd3;
	/** DH value length */
	uint16_t dhvlen;
	/** Sequence number */
	uint32_t seqnum;
	/** Response value (hl bytes) */
	uint8_t rval[];
	/* Followed by hl bytes of challenge value */
	/* Followed by dhvlen bytes of DH value */
} __attribute__ (( packed ));

/** DH-HMAC-CHAP success 1 data */
struct nvmf_auth_dhchap_success1_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd1;
	/** Transaction identifier */
	uint16_t t_id;
	/** Hash length */
	uint8_t hl;
	/** Reserved */
	uint8_t rsvd2;
	/** Response value valid */
	uint8_t rvalid;
	/** Reserved */
	uint8_t rsvd3[7];
	/** Response value (hl bytes) */
	uint8_t rval[];
} __attribute__ (( packed ));

/** DH-HMAC-CHAP success 2 data */
struct nvmf_auth_dhchap_success2_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd1;
	/** Transaction identifier */
	uint16_t t_id;
	/** Reserved */
	uint8_t rsvd2[10];
} __attribute__ (( packed ));

/** DH-HMAC-CHAP failure data */
struct nvmf_auth_dhchap_failure_data {
	/** Authentication type */
	uint8_t auth_type;
	/** Authentication identifier */
	uint8_t auth_id;
	/** Reserved */
	uint16_t rsvd1;
	/** Transaction identifier */
	uint16_t t_id;
	/** Reason code */
	uint8_t rescode;
	/** Reason code extension */
	uint8_t rescode_exp;
} __attribute__ (( packed ));

/** DH-HMAC-CHAP authentication types */
#define NVME_AUTH_COMMON_MESSAGES 0x00
#define NVME_AUTH_DHCHAP_MESSAGES 0x01

/** DH-HMAC-CHAP message identifiers (auth_id) */
#define NVME_AUTH_DHCHAP_MESSAGE_NEGOTIATE 0x00
#define NVME_AUTH_DHCHAP_MESSAGE_CHALLENGE 0x01
#define NVME_AUTH_DHCHAP_MESSAGE_REPLY 0x02
#define NVME_AUTH_DHCHAP_MESSAGE_SUCCESS1 0x03
#define NVME_AUTH_DHCHAP_MESSAGE_SUCCESS2 0x04
#define NVME_AUTH_DHCHAP_MESSAGE_FAILURE2 0xf0
#define NVME_AUTH_DHCHAP_MESSAGE_FAILURE1 0xf1

/** DH-HMAC-CHAP authentication identifier */
#define NVME_AUTH_DHCHAP_AUTH_ID 0x01

/** DH-HMAC-CHAP hash algorithms */
#define NVME_AUTH_HASH_SHA256 0x01
#define NVME_AUTH_HASH_SHA384 0x02
#define NVME_AUTH_HASH_SHA512 0x03

/** DH-HMAC-CHAP DH groups */
#define NVME_AUTH_DHGROUP_NULL 0x00
#define NVME_AUTH_DHGROUP_2048 0x01
#define NVME_AUTH_DHGROUP_3072 0x02
#define NVME_AUTH_DHGROUP_4096 0x03
#define NVME_AUTH_DHGROUP_6144 0x04
#define NVME_AUTH_DHGROUP_8192 0x05

/** DH-HMAC-CHAP security protocol */
#define NVME_AUTH_SECP_NOSC 0x00

/** DH-HMAC-CHAP security protocol identifier */
#define NVME_AUTH_DHCHAP_PROTOCOL_IDENTIFIER 0xe9

/** Maximum number of hash algorithm identifiers */
#define NVME_AUTH_DHCHAP_MAX_HASH_IDS 30

/** Maximum number of DH group identifiers */
#define NVME_AUTH_DHCHAP_MAX_DH_IDS 30

/** Maximum hash digest size */
#define NVME_AUTH_MAX_DIGEST_SIZE 64

/** Maximum DH value size (ffdhe4096) */
#define NVME_AUTH_MAX_DH_SIZE 512

/** Maximum single command data size supported by this driver */
#define NVMETCP_MAX_CMD_DATA 4096

/**
 * Parse Identify Namespace data
 *
 * @v buf		Identify Namespace data (NVME_IDENTIFY_DATA_SIZE bytes)
 * @v capacity		Block device capacity to fill in
 * @ret rc		Return status code
 */
static inline int nvmetcp_identify_ns ( const void *buf,
					struct block_device_capacity *capacity ) {
	const uint8_t *data = buf;
	uint64_t nsze;
	uint8_t flbas;
	uint8_t lbads;
	unsigned int fmt;

	/* Parse Identify Namespace data (NVMe base specification 2.x) */
	nsze = le64_to_cpu ( *( ( uint64_t * ) &data[0] ) );
	flbas = data[26];
	fmt = ( flbas & 0x0f );
	lbads = data[128 + ( fmt * 4 ) + 2 ]; /* nvme_lbaf.ds */
	if ( ( fmt >= 16 ) || ( lbads == 0 ) || ( lbads > 31 ) )
		return -EPROTO;
	capacity->blocks = nsze;
	capacity->blksize = ( 1U << lbads );
	capacity->max_count = ( NVMETCP_MAX_CMD_DATA / capacity->blksize );

	return 0;
}

/** DH-HMAC-CHAP authentication steps */
enum nvmetcp_auth_steps {
        /** Awaiting start: send AuthSend(Negotiate) */
        NVMETCP_AUTH_STEP_START = 0,
        /** AuthSend(Negotiate) in flight: send AuthReceive on completion */
        NVMETCP_AUTH_STEP_COMPLETE_NEGOTIATE,
        /** AuthReceive(challenge) in flight: process data on arrival */
        NVMETCP_AUTH_STEP_CHALLENGE,
        /** AuthSend(Reply) in flight: send AuthReceive on completion */
        NVMETCP_AUTH_STEP_COMPLETE_REPLY,
        /** AuthReceive(success1) in flight: process data on arrival */
        NVMETCP_AUTH_STEP_SUCCESS1,
};

/** NVMe/TCP session phases */
enum nvmetcp_phase {
	/** TCP connection established */
	NVMETCP_PHASE_ICREQ = 0,
	/** ICResp received, sending Connect (admin queue) */
	NVMETCP_PHASE_CONNECT_ADMIN,
	/** Connect(admin) complete, awaiting/sending authentication */
	NVMETCP_PHASE_AUTH,
	/** Authentication complete, sending Property Set (CC) */
	NVMETCP_PHASE_PROP_SET,
	/** Controller enabled, sending Identify Controller */
	NVMETCP_PHASE_IDENTIFY_CTRL,
	/** Identify Controller complete, sending Identify Namespace */
	NVMETCP_PHASE_IDENTIFY_NS,
	/** Identify Namespace complete, opening I/O queue connection */
	NVMETCP_PHASE_ICREQ_IO,
	/** I/O connection established, sending Connect (I/O queue) */
	NVMETCP_PHASE_CONNECT_IO,
	/** I/O queue established, session ready */
	NVMETCP_PHASE_READY,
	/** Session failed */
	NVMETCP_PHASE_FAILED,
};

/** NVMe/TCP session authentication context */
struct nvmetcp_auth {
	/** Authentication message step */
	uint8_t step;
	/** Success1 data validated (authentication succeeded) */
	uint8_t completed;
	/** AuthReceive completion received */
	uint8_t rx_complete;
	/** Command identifier of the final AuthReceive */
	uint16_t rx_cid;
	/** Transaction identifier */
	uint16_t transaction;
	/** Sequence number */
	uint32_t seqnum;
	/** Hash algorithm identifier */
	uint8_t hash_id;
	/** DH group identifier */
	uint8_t dhgid;
	/** Hash length */
	uint8_t hl;
	/** DH value length */
	uint16_t dhvlen;
	/** Challenge value */
	uint8_t cval[NVME_AUTH_MAX_DIGEST_SIZE];
	/** DH shared secret */
	uint8_t session_key[NVME_AUTH_MAX_DH_SIZE];
	/** DH private key */
	uint8_t priv_key[NVME_AUTH_MAX_DH_SIZE];
	/** DH public key */
	uint8_t pub_key[NVME_AUTH_MAX_DH_SIZE];
};

/** NVMe/TCP PDU receive state */
struct nvmetcp_rx {
	/** PDU header buffer */
	uint8_t hdr[128];
	/** Bytes of PDU header received */
	size_t hdr_len;
	/** Bytes of PDU header expected */
	size_t hdr_expect;
	/** Expected PDU data length */
	size_t data_expect;
	/** PDU data received so far */
	size_t data_len;
};

/** NVMe/TCP session */
struct nvmetcp_session {
	/** Reference count */
	struct refcnt refcnt;
	/** Block control interface */
	struct interface control;
	/** Admin queue socket interface */
	struct interface socket;
	/** I/O queue socket interface */
	struct interface io_socket;
	/** Process */
	struct process process;
	/** Session phase */
	unsigned int phase;
	/** Next command identifier */
	uint16_t cid;
	/** Controller identifier (from Connect completion) */
	uint16_t cntlid;

	/* Connection parameters */
	/** Target URI */
	struct uri *uri;
	/** Target host name */
	char *target_host;
	/** Target port */
	uint16_t target_port;
	/** Subsystem NQN */
	char *subsystem_nqn;
	/** Host NQN */
	char *host_nqn;
	/** Authentication secret */
	char *secret;
	/** ACPI descriptor */
	struct acpi_descriptor desc;

	/* Protocol parameters (from ICResp) */
	/** Protocol version format */
	uint16_t pfv;
	/** Header digest enabled */
	uint8_t hdr_digest;
	/** Data digest enabled */
	uint8_t data_digest;
	/** Maximum data capsules per R2T */
	uint32_t maxdata;

	/* Command state (single in-flight command) */
	/** Current command */
	union nvme_command cmd;
	/** Command data buffer (in-capsule or receive buffer) */
	uint8_t cmd_buf[NVMETCP_MAX_CMD_DATA];
	/** Command data length */
	size_t cmd_data_len;
	/** Command data offset received */
	size_t cmd_data_offset;
	/** Command completion */
	struct nvme_completion cqe;
	/** Command in flight (awaiting response) */
	uint8_t tx_in_flight;

	/* Block command state (single in-flight block command) */
	/** Command completion interface */
	struct interface data;
	/** Block data interface */
	struct interface *block_data;
	/** Block data buffer */
	void *block_buffer;
	/** Block data length */
	size_t block_len;
	/** Block write in progress */
	uint8_t block_writing;
	/** Deferred capacity request */
	struct interface *capacity_data;

	/* Receive state */
	/** Admin queue PDU receive state */
	struct nvmetcp_rx rx;
	/** I/O queue PDU receive state */
	struct nvmetcp_rx rx_io;

	/* Identify results */
	/** Namespace identifier */
	uint32_t nsid;
	/** Block capacity */
	struct block_device_capacity capacity;

	/* Authentication context */
	/** Authentication context */
	struct nvmetcp_auth auth;
};

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
extern int nvmetcp_tx_command ( struct nvmetcp_session *nvmetcp,
			       struct interface *socket,
			       union nvme_command *cmd, const void *data,
			       size_t data_len, size_t recv_len );

/**
 * Step DH-HMAC-CHAP authentication
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
extern int nvmetcp_auth_step ( struct nvmetcp_session *nvmetcp );

/**
 * Handle completion of an authentication command
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
extern int nvmetcp_auth_rx_complete ( struct nvmetcp_session *nvmetcp );

/**
 * Handle received authentication data
 *
 * @v nvmetcp		NVMe/TCP session
 * @ret rc		Return status code
 */
extern int nvmetcp_auth_rx_data ( struct nvmetcp_session *nvmetcp );

/**
 * Complete the authentication phase if possible
 *
 * @v nvmetcp		NVMe/TCP session
 *
 * The authentication phase ends only once both the success1 data and
 * the AuthReceive completion have been received.  These may arrive in
 * either order (possibly within the same TCP segment); completing
 * early would cause the AuthReceive completion to be misprocessed as
 * the Property Set completion, skipping the Property Set entirely.
 */
extern void nvmetcp_auth_try_complete ( struct nvmetcp_session *nvmetcp );

#endif /* _IPXE_NVMETCP_H */
