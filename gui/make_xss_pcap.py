#!/usr/bin/env python3
#
# Builds rest/pcap/gui_smoke.pcap, the pcap of the GUI smoke test: the default
# test_01.pcap followed by traffic with XSS payloads in the fields the GUI shows.
# A page that does not escape one of them runs the payload, an alert() that the
# GUI smoke test reports as a FAIL; the number in the alert says the field:
#   1 HTTP Host   2 HTTP User-Agent   3 HTTP URL   4 TLS SNI
#   5 DNS query   6 DHCP host name
#
# Requirements: scapy (python3-scapy). Run it again only when the payloads change:
#   ./make_xss_pcap.py
#

import os
from scapy.all import DHCP, BOOTP, DNS, DNSQR, IP, TCP, UDP, Ether, PcapWriter, RawPcapReader, load_layer

load_layer("tls")
from scapy.layers.tls.all import TLS, TLSClientHello  # noqa: E402
from scapy.layers.tls.extensions import TLS_Ext_ServerName, ServerName  # noqa: E402

PCAP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../rest/pcap")
BASE_PCAP = os.path.join(PCAP_DIR, "test_01.pcap")
OUT_PCAP = os.path.join(PCAP_DIR, "gui_smoke.pcap")


def payload(field):
    return f"<img src=x onerror=alert({field})>"


CLIENT_MAC, ROUTER_MAC = "02:00:00:00:00:01", "02:00:00:00:00:fe"
CLIENT, DNS_SERVER = "192.168.1.250", "192.168.1.1"
HTTP_SERVER, TLS_SERVER = "93.184.216.34", "1.1.1.1"


def tcp_handshake(src, dst, sport, dport):
    return [
        Ether(src=CLIENT_MAC, dst=ROUTER_MAC) / IP(src=src, dst=dst) / TCP(sport=sport, dport=dport, flags="S", seq=1000),
        Ether(src=ROUTER_MAC, dst=CLIENT_MAC) / IP(src=dst, dst=src) / TCP(sport=dport, dport=sport, flags="SA", seq=5000, ack=1001),
        Ether(src=CLIENT_MAC, dst=ROUTER_MAC) / IP(src=src, dst=dst) / TCP(sport=sport, dport=dport, flags="A", seq=1001, ack=5001),
    ]


def xss_packets():
    packets = []

    # 6: DHCP request with the host name option
    packets.append(Ether(src=CLIENT_MAC, dst="ff:ff:ff:ff:ff:ff") / IP(src="0.0.0.0", dst="255.255.255.255") /
                   UDP(sport=68, dport=67) / BOOTP(chaddr=bytes.fromhex(CLIENT_MAC.replace(":", ""))) /
                   DHCP(options=[("message-type", "request"), ("requested_addr", CLIENT), ("hostname", payload(6)), "end"]))

    # 5: DNS query of a name with the payload
    packets.append(Ether(src=CLIENT_MAC, dst=ROUTER_MAC) / IP(src=CLIENT, dst=DNS_SERVER) / UDP(sport=40000, dport=53) /
                   # The spaces are bytes of the label: an unescaped name is still runnable HTML
                   DNS(rd=1, qd=DNSQR(qname=payload(5) + ".example.com")))

    # 1, 2, 3: HTTP request with the payloads in Host, User-Agent and URL
    request = (f"GET /index.html?q={payload(3)} HTTP/1.1\r\nHost: {payload(1)}\r\n"
               f"User-Agent: {payload(2)}\r\nAccept: */*\r\n\r\n").encode()
    response = b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\nok"
    packets += tcp_handshake(CLIENT, HTTP_SERVER, 40001, 80)
    packets.append(Ether(src=CLIENT_MAC, dst=ROUTER_MAC) / IP(src=CLIENT, dst=HTTP_SERVER) /
                   TCP(sport=40001, dport=80, flags="PA", seq=1001, ack=5001) / request)
    packets.append(Ether(src=ROUTER_MAC, dst=CLIENT_MAC) / IP(src=HTTP_SERVER, dst=CLIENT) /
                   TCP(sport=80, dport=40001, flags="PA", seq=5001, ack=1001 + len(request)) / response)

    # 4: TLS ClientHello with the payload as SNI
    hello = TLS(msg=[TLSClientHello(ext=[TLS_Ext_ServerName(servernames=[ServerName(servername=payload(4).encode())])])])
    packets += tcp_handshake(CLIENT, TLS_SERVER, 40002, 443)
    packets.append(Ether(src=CLIENT_MAC, dst=ROUTER_MAC) / IP(src=CLIENT, dst=TLS_SERVER) /
                   TCP(sport=40002, dport=443, flags="PA", seq=1001, ack=5001) / hello)

    return packets


def main():
    # The packets of test_01.pcap are copied byte by byte, not rebuilt by scapy
    base = list(RawPcapReader(BASE_PCAP))
    last = base[-1][1]
    # After the default traffic, 10 ms apart: ntopng reads the pcap in time order
    start = last.sec + last.usec / 1e6 + 1
    xss = xss_packets()

    with PcapWriter(OUT_PCAP, linktype=1, sync=True) as out:
        # write_packet() does not write the file header (write() does)
        out.write_header(None)
        for data, meta in base:
            out.write_packet(data, sec=meta.sec, usec=meta.usec, caplen=meta.caplen, wirelen=meta.wirelen)
        for i, packet in enumerate(xss):
            packet.time = start + i * 0.01
            out.write(packet)
    print(f"{OUT_PCAP}: {len(base)} packets of test_01.pcap + {len(xss)} with XSS payloads")


if __name__ == "__main__":
    main()
