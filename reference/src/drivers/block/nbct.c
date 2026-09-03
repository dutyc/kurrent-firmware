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

FILE_LICENCE ( BSD2 );
FILE_SECBOOT ( PERMITTED );

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <byteswap.h>
#include <ipxe/acpi.h>
#include <ipxe/nvmetcp.h>
#include <ipxe/nbct.h>

/** @file
 *
 * NVMe boot credentials table (NBCT)
 *
 * 固件在 sanboot 挂载 NVMe-oF 盘后，把会话级认证凭据
 * （DH-HMAC-CHAP secret、host NQN）写入自定义 ACPI 表 NBCT，
 * 供内核/initramfs 接力阶段读取后逐条 `nvme connect` 附加
 * （--nkey/--hostnqn），避免内核侧二次网络获取凭证。
 *
 * 表内容为会话级资产：仅存于内存（ACPI 表），不落 NVRAM，
 * 随引导会话消亡，符合无状态盘原则。设计参照 iBFT 的
 * acpi_model 注册模式（iSCSI 会话经 acpi_describe 注册，
 * efi_block_describe 触发 acpi_install 重装）；记录采用
 * 定长结构，便于 initramfs 以 POSIX sh + dd 按固定偏移解析。
 */

/** NBCT table signature */
#define NBCT_SIGNATURE ACPI_SIGNATURE ( 'N', 'B', 'C', 'T' )

/** Length of each NBCT entry (fixed, for initramfs dd parsing) */
#define NBCT_ENTRY_LEN 1024

/** NBCT entry field lengths (including NUL terminator) */
#define NBCT_TRADDR_LEN 128
#define NBCT_TRSVCID_LEN 16
#define NBCT_NQN_LEN 256
#define NBCT_HOSTNQN_LEN 256
#define NBCT_SECRET_LEN 320

/** NBCT table body header */
struct nbct_header {
	/** Number of entries */
	uint8_t count;
	/** Reserved */
	uint8_t reserved[3];
} __attribute__ (( packed ));

/** NBCT entry (one per NVMe/TCP session) */
struct nbct_entry {
	/** Entry index */
	uint16_t index;
	/** Reserved */
	uint16_t reserved;
	/** Transport address (target host or IP) */
	char traddr[NBCT_TRADDR_LEN];
	/** Transport service id (port) */
	char trsvcid[NBCT_TRSVCID_LEN];
	/** Subsystem NQN */
	char nqn[NBCT_NQN_LEN];
	/** Host NQN */
	char hostnqn[NBCT_HOSTNQN_LEN];
	/** DH-HMAC-CHAP secret (empty if unauthenticated) */
	char secret[NBCT_SECRET_LEN];
} __attribute__ (( packed ));

/**
 * Check whether a NBCT descriptor is complete
 *
 * @v desc		ACPI descriptor
 * @ret rc		Return status code
 */
static int nbct_complete ( struct acpi_descriptor *desc ) {
	struct nvmetcp_session *nvmetcp =
		container_of ( desc, struct nvmetcp_session, desc );

	/* Fail if the session has no subsystem NQN yet */
	if ( ! nvmetcp->subsystem_nqn )
		return -EAGAIN;

	return 0;
}

/**
 * Install NBCT table
 *
 * @v install		Table installation method
 * @ret rc		Return status code
 */
static int nbct_install ( int ( * install ) ( struct acpi_header *acpi ) ) {
	struct nvmetcp_session *nvmetcp;
	struct acpi_header *acpi;
	struct nbct_header *hdr;
	struct nbct_entry *entry;
	unsigned int count = 0;
	unsigned int i;
	size_t len;
	int rc;

	/* Count sessions */
	list_for_each_entry ( nvmetcp, &nbct_model.descs, desc.list )
		count++;
	if ( ! count )
		return 0;

	/* Allocate table */
	len = ( sizeof ( *acpi ) + sizeof ( *hdr ) +
		( count * NBCT_ENTRY_LEN ) );
	acpi = zalloc ( len );
	if ( ! acpi )
		return -ENOMEM;

	/* Fill in ACPI header */
	acpi->signature = cpu_to_le32 ( NBCT_SIGNATURE );
	acpi->length = cpu_to_le32 ( len );
	acpi->revision = 1;
	memcpy ( acpi->oem_id, "NBCT", 4 );
	memcpy ( acpi->oem_table_id, "iPXE", 4 );

	/* Fill in entries */
	hdr = ( ( void * ) acpi ) + sizeof ( *acpi );
	hdr->count = count;
	i = 0;
	list_for_each_entry ( nvmetcp, &nbct_model.descs, desc.list ) {
		entry = ( ( void * ) ( hdr + 1 ) + ( i * NBCT_ENTRY_LEN ) );
		entry->index = cpu_to_le16 ( i );
		snprintf ( entry->traddr, sizeof ( entry->traddr ), "%s",
			   nvmetcp->target_host );
		snprintf ( entry->trsvcid, sizeof ( entry->trsvcid ), "%d",
			   nvmetcp->target_port );
		snprintf ( entry->nqn, sizeof ( entry->nqn ), "%s",
			   nvmetcp->subsystem_nqn );
		snprintf ( entry->hostnqn, sizeof ( entry->hostnqn ), "%s",
			   nvmetcp->host_nqn );
		if ( nvmetcp->secret )
			snprintf ( entry->secret, sizeof ( entry->secret ),
				   "%s", nvmetcp->secret );
		i++;
	}

	/* Install ACPI table */
	if ( ( rc = install ( acpi ) ) != 0 ) {
		DBG ( "NBCT could not install: %s\n", strerror ( rc ) );
		free ( acpi );
		return rc;
	}

	free ( acpi );
	return 0;
}

/** NBCT model */
struct acpi_model nbct_model __acpi_model = {
	.descs = LIST_HEAD_INIT ( nbct_model.descs ),
	.complete = nbct_complete,
	.install = nbct_install,
};
