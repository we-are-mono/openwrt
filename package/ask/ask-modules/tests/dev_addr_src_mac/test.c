/* Host test: the source MAC cdx puts on hardware-forwarded frames.
 *
 * Runs the REAL text of the two tx-info builders of cdx/devman.c
 * (dpa_get_out_tx_info_by_itf_id and dpa_get_tx_info_by_itf), extracted
 * verbatim by run.sh from the pinned ASK source - after the fixes under
 * package/ask/ask-modules/patches when present - against the stubbed
 * types in stubs.h, and checks the MAC that lands in l2hdr[6..11], the
 * source MAC of the frame header.
 *
 * A WAN port whose MAC was spoofed must source frames with the current
 * net_dev->dev_addr, not the factory net_dev->perm_addr captured at
 * registration. Unpatched source copies perm_addr into eth_info.mac_addr
 * at registration (devman.c:310) and the builders read that copy, so S1,
 * S5 and S6a fail for both builders; a fix that reads dev_addr live makes
 * all scenarios pass.
 *
 * Not standalone: run.sh extracts the function text and the verbatim
 * #define NULL_MAC_ADDR and registration lines into generated .inc files
 * and compiles this file against them.
 */
#include "stubs.h"
#include "null_mac.inc"      /* #define NULL_MAC_ADDR, verbatim from devman.c */

static spinlock_t dpa_devlist_lock;
static struct dpa_iface_info *g_iface;

static struct dpa_iface_info *dpa_get_ifinfo_by_itfid(uint32_t id)
{
	return (g_iface && g_iface->itf_id == id) ? g_iface : NULL;
}

/* The helpers answer "success, nothing to add": no scenario exercises the
 * fqid, dscp-map, logical-type or tunnel-classification side paths. */
static int __attribute__((unused)) dpa_check_for_logical_iface_types(
	struct itf_stub *input_itf, struct itf_stub *underlying_input_itf,
	struct dpa_l2hdr_info *l2_info, struct dpa_l3hdr_info *l3_info)
{
	(void)input_itf; (void)underlying_input_itf; (void)l2_info; (void)l3_info;
	return 0;
}
static int __attribute__((unused)) dpa_get_fqid_from_eth(struct eth_iface_info *e, void *fqid, void *x)
{ (void)e; (void)fqid; (void)x; return 0; }
static int __attribute__((unused)) cdx_get_tx_dscp_fq_map(struct eth_iface_info *e, void *m, void *x)
{ (void)e; (void)m; (void)x; return 0; }
static int __attribute__((unused)) cdx_get_tx_dscp_vlanpcp_map_enable(uint32_t portid)
{ (void)portid; return 0; }
static int __attribute__((unused)) is_ipv6_addr_any(const uint8_t *addr)
{ (void)addr; return 0; }
static void __attribute__((unused)) dpaa_get_vap_fwd_fq(uint32_t vap, void *fqid, int q)
{ (void)vap; (void)fqid; (void)q; }

#include "fn_ipsec.inc"      /* dpa_get_out_tx_info_by_itf_id, verbatim */
#include "fn_flow.inc"       /* dpa_get_tx_info_by_itf, verbatim */

/* Port registration: the MAC capture of get_eth_iface_info()
 * (devman.c:310). Unpatched source copies the factory MAC into
 * eth_info.mac_addr here; a patched source includes an empty line. */
static void register_eth_port(struct net_device *device, struct eth_iface_info *eth_info)
{
	eth_info->net_dev = device;
#include "reg_line.inc"
}

static const uint8_t FACTORY[6] = {0xe8, 0xf6, 0xd7, 0x00, 0x22, 0xcd};
static const uint8_t SPOOF[6]   = {0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee}; /* stands in for the ISP MAC */
static const uint8_t BRMAC[6]   = {0xe8, 0xf6, 0xd7, 0x00, 0x22, 0xcb};

static int failures;

static const char *hex(const uint8_t m[6])
{
	static char b[8][18];
	static int i;
	char *p = b[i++ & 7];
	snprintf(p, 18, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
	return p;
}

static void check(const char *fn, const char *id, const char *desc,
		  int rc, const uint8_t got[6], const uint8_t want[6])
{
	int ok = (rc == SUCCESS) && !memcmp(got, want, ETH_ALEN);
	printf("%s [%s] %s %s want=%s got=%s\n", ok ? "PASS" : "FAIL",
	       fn, id, desc, hex(want), hex(got));
	if (!ok)
		failures++;
}

/* Run one scenario against both builders and compare each result. */
static void scenario(const char *id, const char *desc,
		     struct dpa_iface_info *egress, const uint8_t want[6])
{
	struct itf_stub egress_itf = { .index = egress->itf_id };
	struct itf_stub ingress_itf = { .index = 9 };
	struct RouteEntry rt = { .itf = &egress_itf, .id = 1, .mtu = 1500,
				 .dstmac = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55} };
	struct dpa_l2hdr_info l2;
	struct dpa_l3hdr_info l3;
	uint8_t qos[64];
	int rc;

	g_iface = egress;

	rc = dpa_get_out_tx_info_by_itf_id(&rt, &l2, &l3);
	check("ipsec", id, desc, rc, &l2.l2hdr[6], want);

	rt.underlying_input_itf = &ingress_itf; /* the flow builder requires non-NULL */
	memset(qos, 0, sizeof qos);             /* void *qosinfo; only cast by the builder */
	rc = dpa_get_tx_info_by_itf(&rt, &l2, &l3, NULL, qos, 0);
	check("flow", id, desc, rc, &l2.l2hdr[6], want);
}

int main(void)
{
	struct net_device nd;
	struct dpa_iface_info eth, vlan;

	/* S1: WAN port, spoof applied BEFORE the port is registered with cdx */
	memset(&eth, 0, sizeof eth);
	memcpy(nd.perm_addr, FACTORY, 6); memcpy(nd.dev_addr, SPOOF, 6);
	eth.itf_id = 1; eth.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
	register_eth_port(&nd, &eth.eth_info);
	scenario("S1", "plain ethernet WAN, spoof set before registration", &eth, SPOOF);

	/* S2 control: same port, no spoof */
	memset(&eth, 0, sizeof eth);
	memcpy(nd.perm_addr, FACTORY, 6); memcpy(nd.dev_addr, FACTORY, 6);
	eth.itf_id = 1; eth.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
	register_eth_port(&nd, &eth.eth_info);
	scenario("S2", "control: plain ethernet, no spoof", &eth, FACTORY);

	/* S3 control: bridged port (LAN uplink in a bridge) uses the bridge MAC */
	memset(&eth, 0, sizeof eth);
	memcpy(nd.perm_addr, FACTORY, 6); memcpy(nd.dev_addr, SPOOF, 6);
	eth.itf_id = 1; eth.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
	register_eth_port(&nd, &eth.eth_info);
	eth.eth_info.is_bridged = 1; memcpy(eth.eth_info.br_mac_addr, BRMAC, 6); /* as dpa_set_bridged_itf() */
	scenario("S3", "control: bridged ethernet uses bridge MAC", &eth, BRMAC);

	/* S4 control: VLAN child; its MAC is passed in by cmm (devman.c:2213) */
	memset(&eth, 0, sizeof eth); memset(&vlan, 0, sizeof vlan);
	memcpy(nd.perm_addr, FACTORY, 6); memcpy(nd.dev_addr, SPOOF, 6);
	eth.itf_id = 1; eth.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
	register_eth_port(&nd, &eth.eth_info);
	vlan.itf_id = 2; vlan.if_flags = IF_TYPE_VLAN; vlan.vlan_info.parent = &eth; vlan.vlan_info.vlan_id = 10;
	memcpy(vlan.vlan_info.mac_addr, SPOOF, 6);
	scenario("S4", "control: VLAN over ethernet uses the VLAN's own MAC", &vlan, SPOOF);

	/* S5: spoof applied AFTER the port was registered (netifd runs later) */
	memset(&eth, 0, sizeof eth);
	memcpy(nd.perm_addr, FACTORY, 6); memcpy(nd.dev_addr, FACTORY, 6);
	eth.itf_id = 1; eth.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
	register_eth_port(&nd, &eth.eth_info);
	memcpy(nd.dev_addr, SPOOF, 6);                 /* MAC changed after registration */
	scenario("S5", "plain ethernet WAN, spoof set AFTER registration", &eth, SPOOF);

	/* S6: the reporter's topology:
	 *   eth3 = WAN1 (ONT stick): plain ethernet, MAC spoofed to the ISP's
	 *   eth0 = WAN2 (backup):    plain ethernet, factory MAC
	 *   eth4 = LAN uplink:       member of br-lan (bridge MAC) */
	{
		static const uint8_t F3[6] = {0xe8, 0xf6, 0xd7, 0x00, 0x22, 0xcd};
		static const uint8_t F0[6] = {0xe8, 0xf6, 0xd7, 0x00, 0x22, 0xca};
		static const uint8_t F4[6] = {0xe8, 0xf6, 0xd7, 0x00, 0x22, 0xce};
		struct net_device n3, n0, n4;
		struct dpa_iface_info e3, e0, e4;

		memset(&e3, 0, sizeof e3); memset(&e0, 0, sizeof e0); memset(&e4, 0, sizeof e4);
		memcpy(n3.perm_addr, F3, 6); memcpy(n3.dev_addr, SPOOF, 6);   /* spoofed */
		memcpy(n0.perm_addr, F0, 6); memcpy(n0.dev_addr, F0, 6);      /* default */
		memcpy(n4.perm_addr, F4, 6); memcpy(n4.dev_addr, F4, 6);
		e3.itf_id = 3; e3.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
		e0.itf_id = 0; e0.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
		e4.itf_id = 4; e4.if_flags = IF_TYPE_ETHERNET | IF_TYPE_PHYSICAL;
		register_eth_port(&n3, &e3.eth_info);
		register_eth_port(&n0, &e0.eth_info);
		register_eth_port(&n4, &e4.eth_info);
		e4.eth_info.is_bridged = 1; memcpy(e4.eth_info.br_mac_addr, BRMAC, 6);

		scenario("S6a", "LAN->WAN1 egress eth3 (spoofed ISP MAC)", &e3, SPOOF);
		scenario("S6b", "LAN->WAN2 egress eth0 (backup, factory MAC)", &e0, F0);
		scenario("S6c", "WAN->LAN egress eth4 (bridged, br-lan MAC)", &e4, BRMAC);
	}

	printf("=> %d failure(s)\n", failures);
	return failures ? 1 : 0;
}
