/* Minimal userspace stand-ins for the kernel/CDX types used by the two
 * tx-info builders of cdx/devman.c in the pinned ASK source
 * (dpa_get_out_tx_info_by_itf_id at devman.c:1003-1206 and
 * dpa_get_tx_info_by_itf at devman.c:1263-1545). Field names follow the
 * function bodies; layouts are NOT the real ones. Macro values are copied
 * from the pinned cdx headers (cdx/control_tunnel.h for TNL_MODE_*).
 */
#ifndef STUBS_H
#define STUBS_H
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define ETH_ALEN 6
#define ETHER_ADDR_LEN 6
#define SUCCESS 0
#define FAILURE -1
#define IPV6_ADDRESS_LENGTH 16
#define DPA_CLS_HM_MAX_VLANs 6
#define ETHERTYPE_VLAN 0x8100
#define TNL_MODE_6O4 1
#define TNL_MODE_4O6 2
#define IF_TYPE_ETHERNET (1 << 0)
#define IF_TYPE_VLAN     (1 << 1)
#define IF_TYPE_PPPOE    (1 << 2)
#define IF_TYPE_TUNNEL   (1 << 3)
#define IF_TYPE_WLAN     (1 << 5)
#define IF_TYPE_PHYSICAL (1 << 7)

#define DPA_ERROR(fmt, ...) fprintf(stderr, "DPA_ERROR: " fmt, ##__VA_ARGS__)
#define DPA_INFO(fmt, ...)  fprintf(stderr, "DPA_INFO: " fmt, ##__VA_ARGS__)

typedef int spinlock_t;
#define spin_lock(l)   ((void)(l))
#define spin_unlock(l) ((void)(l))

struct net_device {
	uint8_t perm_addr[6];   /* factory MAC            */
	uint8_t dev_addr[6];    /* currently configured   */
};

struct dpa_iface_info;

struct eth_iface_info {
	struct net_device *net_dev;
	uint8_t  is_bridged;
	uint8_t  br_mac_addr[6];
	uint8_t  mac_addr[6];   /* the unpatched builders read this copy */
	uint32_t portid;
};
struct wlan_iface_info {
	uint8_t  is_bridged;
	uint8_t  br_mac_addr[6];
	uint8_t  mac_addr[6];
	uint32_t vap_id;
};
struct vlan_iface_info {
	struct dpa_iface_info *parent;
	uint8_t  is_bridged;
	uint8_t  br_mac_addr[6];
	uint8_t  mac_addr[6];
	uint16_t vlan_id;
};
struct pppoe_iface_info {
	struct dpa_iface_info *parent;
	uint16_t session_id;
	uint8_t  mac_addr[6];
};
struct tunnel_iface_info {
	struct dpa_iface_info *parent;
	uint32_t header_size;
	uint8_t  proto, mode;
	uint32_t flags;
	uint8_t  header[64], local_ip[16], remote_ip[16], dstmac[6];
};
struct dpa_iface_info {
	uint32_t if_flags;
	uint32_t itf_id;
	char     name[16];
	struct eth_iface_info    eth_info;
	struct wlan_iface_info   wlan_info;
	struct vlan_iface_info   vlan_info;
	struct pppoe_iface_info  pppoe_info;
	struct tunnel_iface_info tunnel_info;
};

struct egress_vlan_hdr { uint16_t tpid, tci; };
struct dpa_l2hdr_info {
	uint32_t mtu;
	uint8_t  l2hdr[32];
	uint32_t fqid;
	uint8_t  is_wlan_iface;
	uint8_t  num_egress_vlan_hdrs;
	struct egress_vlan_hdr egress_vlan_hdrs[DPA_CLS_HM_MAX_VLANs];
	uint8_t  is_dscp_fq_map;
	uint8_t  dscp_vlanpcp_map_enable;
	uint16_t pppoe_sess_id;
	uint8_t  add_pppoe_hdr;
	uint8_t  ac_mac_addr[6];
};
/* The tunnel builders fill the destination address of the outer tunnel
 * header through header_v4 / header_v6; only DestinationAddress is named. */
struct tunneled_ipv4_hdr { uint32_t DestinationAddress; };
struct tunneled_ipv6_hdr { uint8_t DestinationAddress[IPV6_ADDRESS_LENGTH]; };
struct dpa_l3hdr_info {
	uint8_t  add_tnl_header;
	uint32_t header_size;
	uint8_t  proto, mode;
	uint32_t tunnel_flags;
	uint8_t  header[64], local_ip[16], remote_ip[16];
	struct tunneled_ipv4_hdr header_v4;
	struct tunneled_ipv6_hdr header_v6;
};
struct itf_stub { uint32_t index; };
struct RouteEntry {
	struct itf_stub *itf;                      /* egress            */
	struct itf_stub *input_itf;                /* may be NULL       */
	struct itf_stub *underlying_input_itf;     /* must be non-NULL  */
	uint32_t id, mtu;
	uint32_t Daddr_v4;
	uint8_t  Daddr_v6[IPV6_ADDRESS_LENGTH];
	uint8_t  dstmac[6];
};
typedef struct RouteEntry *PRouteEntry;

#endif
