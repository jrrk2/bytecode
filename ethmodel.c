// ethmodel: see ethmodel.h.  Prints what the device sees:
//   eth: TX <len> <hex bytes>   a frame the program sent
//   eth: LEDS <hex>
//   uart: <line>                UART output, a line at a time
//
// Besides the canned frames it plays a DHCP server (dhcp_server, below):
// it ignores the first DISCOVER (to make the client retransmit), answers
// the next with an OFFER of 192.168.1.77 and a REQUEST for it with an ACK.
// While an exchange is in progress the canned frames wait; afterwards they
// are addressed to the leased address.  Time (ETH_TIMER_MS) is simulated:
// ten milliseconds per ETH_STATUS poll, the same for every run.
//
// It also plays the netboot host, 192.168.1.106: it answers ARP for that
// address and serves the file named by $ETHMODEL_TFTP_FILE by TFTP on port
// 6969 (a DATA block per ACK).  The program stages the image through
// 0x10000.. and writes ETH_BOOT; the model then checks the staged bytes
// against the file ("eth: BOOT ...") and the run is done.
#include "ethmodel.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
  RX_BASE = 0x0000, TX_BASE = 0x0800, WINDOW = 0x0800,
  ETH_STATUS = 0x1000, ETH_STATUS_PHY = 0x1001, ETH_RXLEN = 0x1002,
  ETH_TXLEN = 0x1003, LEDS = 0x1004, UART = 0x1005, ETH_TIMER_MS = 0x1006,
  ETH_BOOT = 0x1007, STAGE_BASE = 0x10000, STAGE_SIZE = 0x10000,
};
enum { TFTP_PORT = 6969, TFTP_TID = 6970, TFTP_BLOCK = 512 };
enum { RX_VALID = 1, TX_BUSY = 2, RX_TRUNC = 4 };
enum { PHY_STATUS = 0x0303, IDLE_POLLS_WHEN_DONE = 3 };

static const uint8_t host_mac[6] = {0x10, 0xe2, 0xd5, 0x00, 0x00, 0x01};
static const uint8_t host_ip[4] = {192, 168, 1, 106};
static const uint8_t vm_mac[6] = {0x02, 0x00, 0x00, 0x4d, 0x47, 0x31};
static const uint8_t other_ip[4] = {192, 168, 1, 43};
static const uint8_t server_mac[6] = {0x10, 0xe2, 0xd5, 0x00, 0x00, 0xfe};
static const uint8_t server_ip[4] = {192, 168, 1, 1};
static const uint8_t leased_ip[4] = {192, 168, 1, 77};
static uint8_t vm_ip_now[4] = {192, 168, 1, 42};   // .77 once leased

typedef struct { int len; uint8_t b[1536]; } frame_t;
static frame_t frames[4];
static int nframes, next_frame, rx_valid, rx_len, idle_polls, initialised;
static long now_ms;
// DHCP server: replies waiting to be received, and whether an exchange is
// under way (the canned frames wait for it)
static int dhcp_in_progress, discovers_seen;

// Frames waiting to be received ahead of the canned ones: DHCP, ARP and
// TFTP replies.
enum { QUEUE = 8 };
static frame_t reply_queue[QUEUE];
static int queue_head, queue_len;
static frame_t *reply_slot(void) {
  if (queue_len == QUEUE) { fprintf(stderr, "ethmodel: reply queue full\n"); queue_len--; }
  frame_t *f = &reply_queue[(queue_head + queue_len++) % QUEUE];
  memset(f, 0, sizeof *f);
  return f;
}

// netboot: the staging window, the TFTP transfer, and the boot
static uint8_t stage[STAGE_SIZE];
static uint8_t *tftp_data;
static long tftp_size;
static int tftp_active, tftp_last_block_sent, booted;
static int frame_mode;   // driven by ethmodel_tx_frame/_rx_frame: replies stay queued
static uint8_t rxbuf[WINDOW], txbuf[WINDOW];
static char uart_line[256];
static int uart_len;

static uint16_t checksum(const uint8_t *p, int len) {
  uint32_t s = 0;
  for (int i = 0; i + 1 < len; i += 2) s += (p[i] << 8) | p[i + 1];
  if (len & 1) s += p[len - 1] << 8;
  while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
  return (uint16_t)~s;
}

static void arp_request(frame_t *f, const uint8_t *target_ip) {
  uint8_t *b = f->b;
  memset(b, 0xff, 6);                       // broadcast
  memcpy(b + 6, host_mac, 6);
  b[12] = 0x08; b[13] = 0x06;               // ARP
  b[14] = 0x00; b[15] = 0x01; b[16] = 0x08; b[17] = 0x00; b[18] = 6; b[19] = 4;
  b[20] = 0x00; b[21] = 0x01;               // request
  memcpy(b + 22, host_mac, 6); memcpy(b + 28, host_ip, 4);
  memset(b + 32, 0, 6); memcpy(b + 38, target_ip, 4);
  f->len = 60;                              // padded, as it arrives off the wire
}

static void icmp_echo_request(frame_t *f, int payload) {
  uint8_t *b = f->b;
  const int ip_len = 20 + 8 + payload;
  memcpy(b, vm_mac, 6); memcpy(b + 6, host_mac, 6);
  b[12] = 0x08; b[13] = 0x00;               // IPv4
  uint8_t *ip = b + 14;
  ip[0] = 0x45; ip[1] = 0; ip[2] = ip_len >> 8; ip[3] = ip_len & 0xFF;
  ip[4] = 0x12; ip[5] = 0x34; ip[6] = 0x40; ip[7] = 0; ip[8] = 64; ip[9] = 1;
  ip[10] = ip[11] = 0;
  memcpy(ip + 12, host_ip, 4); memcpy(ip + 16, vm_ip_now, 4);
  uint16_t s = checksum(ip, 20); ip[10] = s >> 8; ip[11] = s & 0xFF;
  uint8_t *icmp = ip + 20;
  icmp[0] = 8; icmp[1] = 0; icmp[2] = icmp[3] = 0;
  icmp[4] = 0x00; icmp[5] = 0x01; icmp[6] = 0x00; icmp[7] = 0x01;   // id 1, seq 1
  for (int i = 0; i < payload; i++) icmp[8 + i] = 'a' + i % 26;
  s = checksum(icmp, 8 + payload); icmp[2] = s >> 8; icmp[3] = s & 0xFF;
  f->len = 14 + ip_len;
}

static void make_canned_frames(void) {
  nframes = 0;
  arp_request(&frames[nframes++], vm_ip_now);
  arp_request(&frames[nframes++], other_ip);     // not ours: no reply
  icmp_echo_request(&frames[nframes++], 32);
  icmp_echo_request(&frames[nframes++], 1000);   // a frame well over 256 bytes
}

static void deliver(const frame_t *f) {
  memset(rxbuf, 0, sizeof rxbuf);
  memcpy(rxbuf, f->b, f->len);
  rx_len = f->len;
  rx_valid = 1;
}

// Called whenever the RX window is free: a DHCP reply first, then the next
// canned frame unless a DHCP exchange is under way.
static void load_next_frame(void) {
  if (queue_len) { deliver(&reply_queue[queue_head]); queue_head = (queue_head + 1) % QUEUE; queue_len--; return; }
  if (dhcp_in_progress || next_frame >= nframes) return;
  deliver(&frames[next_frame++]);
}

static void init(void) {
  if (initialised) return;
  initialised = 1;
  make_canned_frames();
}

// ---- the DHCP server ----
static void put16(uint8_t *p, int v) { p[0] = v >> 8; p[1] = v & 0xFF; }

static void dhcp_reply_frame(const uint8_t *req, int type) {
  frame_t *f = reply_slot();
  uint8_t *b = f->b, *ip = b + 14, *udp = ip + 20, *bootp = udp + 8, *o;
  const int bootp_len = 300, ip_len = 20 + 8 + bootp_len;
  memset(b, 0, sizeof f->b);
  memset(b, 0xff, 6); memcpy(b + 6, server_mac, 6);   // broadcast: the client has no address
  b[12] = 0x08; b[13] = 0x00;
  ip[0] = 0x45; put16(ip + 2, ip_len); ip[8] = 64; ip[9] = 17;
  memcpy(ip + 12, server_ip, 4); memset(ip + 16, 0xff, 4);
  uint16_t s = checksum(ip, 20); put16(ip + 10, s);
  put16(udp, 67); put16(udp + 2, 68); put16(udp + 4, 8 + bootp_len);   // UDP checksum 0: none
  bootp[0] = 2; bootp[1] = 1; bootp[2] = 6;
  memcpy(bootp + 4, req + 4, 4);                     // xid
  bootp[10] = 0x80;                                  // broadcast flag
  memcpy(bootp + 16, leased_ip, 4);                  // yiaddr
  memcpy(bootp + 28, req + 28, 16);                  // chaddr
  o = bootp + 236;
  o[0] = 0x63; o[1] = 0x82; o[2] = 0x53; o[3] = 0x63; o += 4;
  *o++ = 53; *o++ = 1; *o++ = type;
  *o++ = 54; *o++ = 4; memcpy(o, server_ip, 4); o += 4;
  *o++ = 51; *o++ = 4; *o++ = 0; *o++ = 0; *o++ = 0x0e; *o++ = 0x10;   // lease 3600 s
  *o++ = 1; *o++ = 4; *o++ = 255; *o++ = 255; *o++ = 255; *o++ = 0;
  *o++ = 3; *o++ = 4; memcpy(o, server_ip, 4); o += 4;
  *o++ = 255;
  f->len = 14 + ip_len;
}

// ---- the netboot host: ARP and TFTP ----
static void host_arp_reply(const uint8_t *req) {
  frame_t *f = reply_slot();
  uint8_t *b = f->b;
  memcpy(b, req + 6, 6); memcpy(b + 6, host_mac, 6);
  b[12] = 0x08; b[13] = 0x06;
  b[14] = 0x00; b[15] = 0x01; b[16] = 0x08; b[17] = 0x00; b[18] = 6; b[19] = 4;
  b[20] = 0x00; b[21] = 0x02;
  memcpy(b + 22, host_mac, 6); memcpy(b + 28, host_ip, 4);
  memcpy(b + 32, req + 22, 6); memcpy(b + 38, req + 28, 4);
  f->len = 60;
}

// A UDP datagram from the host (TFTP_TID) to the program at `to` (its IP
// header and ports taken from the program's request).
static void host_udp(const uint8_t *req, const uint8_t *payload, int n) {
  frame_t *f = reply_slot();
  uint8_t *b = f->b, *ip = b + 14, *udp = ip + 20;
  const uint8_t *rip = req + 14, *rudp = rip + (rip[0] & 15) * 4;
  memcpy(b, req + 6, 6); memcpy(b + 6, host_mac, 6);
  b[12] = 0x08; b[13] = 0x00;
  ip[0] = 0x45; put16(ip + 2, 20 + 8 + n); ip[8] = 64; ip[9] = 17;
  memcpy(ip + 12, host_ip, 4); memcpy(ip + 16, rip + 12, 4);
  put16(ip + 10, checksum(ip, 20));
  put16(udp, TFTP_TID); memcpy(udp + 2, rudp, 2); put16(udp + 4, 8 + n);
  memcpy(udp + 8, payload, n);
  f->len = 14 + 20 + 8 + n < 60 ? 60 : 14 + 20 + 8 + n;
}

static void tftp_send_block(const uint8_t *req, int block) {
  uint8_t p[4 + TFTP_BLOCK];
  long off = (long)(block - 1) * TFTP_BLOCK;
  int n = tftp_size - off < TFTP_BLOCK ? (int)(tftp_size - off) : TFTP_BLOCK;
  p[0] = 0; p[1] = 3; put16(p + 2, block);
  memcpy(p + 4, tftp_data + off, n);
  host_udp(req, p, 4 + n);
  tftp_last_block_sent = block;
}

static void tftp_server(const uint8_t *b, int len) {
  const uint8_t *ip = b + 14, *udp, *p;
  int dport;
  if (len < 14 + 20 + 8 + 4 || b[12] != 0x08 || b[13] != 0x00 || ip[9] != 17
      || memcmp(ip + 16, host_ip, 4) != 0) return;
  udp = ip + (ip[0] & 15) * 4;
  dport = (udp[2] << 8) | udp[3];
  p = udp + 8;
  if (dport == TFTP_PORT && p[0] == 0 && p[1] == 1) {          // RRQ
    const char *name = getenv("ETHMODEL_TFTP_FILE");
    FILE *fp = name ? fopen(name, "rb") : NULL;
    printf("eth: TFTP RRQ %s\n", (const char *)p + 2);
    if (!fp) {
      uint8_t e[] = {0, 5, 0, 1, 'n', 'o', ' ', 'f', 'i', 'l', 'e', 0};
      host_udp(b, e, sizeof e);
      return;
    }
    free(tftp_data);
    tftp_data = (uint8_t *)malloc(STAGE_SIZE + 1);
    tftp_size = fread(tftp_data, 1, STAGE_SIZE + 1, fp);
    fclose(fp);
    tftp_active = 1;
    tftp_send_block(b, 1);
  } else if (dport == TFTP_TID && tftp_active && p[0] == 0 && p[1] == 4) {   // ACK
    int block = (p[2] << 8) | p[3];
    if (block == tftp_last_block_sent && (long)block * TFTP_BLOCK <= tftp_size)
      tftp_send_block(b, block + 1);   // a short (or empty) block ends the file
  }
}

static void host_arp(const uint8_t *b, int len) {
  if (len >= 42 && b[12] == 0x08 && b[13] == 0x06 && b[21] == 1 && memcmp(b + 38, host_ip, 4) == 0)
    host_arp_reply(b);
}

// A frame the program sent: a DHCP DISCOVER or REQUEST gets its reply.
static void dhcp_server(const uint8_t *b, int len) {
  const uint8_t *ip = b + 14, *udp, *bootp, *o, *end = b + len;
  int msg = 0;
  if (len < 14 + 20 + 8 + 240 || b[12] != 0x08 || b[13] != 0x00 || ip[9] != 17) return;
  udp = ip + (ip[0] & 15) * 4;
  if (udp[2] != 0 || udp[3] != 67) return;
  bootp = udp + 8;
  if (bootp[0] != 1 || bootp[236] != 0x63 || bootp[237] != 0x82 || bootp[238] != 0x53 || bootp[239] != 0x63) return;
  for (o = bootp + 240; o < end && *o != 255; o += (*o == 0) ? 1 : 2 + o[1])
    if (*o == 53) msg = o[2];
  if (msg == 1) {                                    // DISCOVER
    dhcp_in_progress = 1;
    if (discovers_seen++ == 0 && !getenv("ETHMODEL_FAST_DHCP")) return;   // ignore the first: the client must retry
    dhcp_reply_frame(bootp, 2);                      // OFFER
  } else if (msg == 3) {                             // REQUEST
    dhcp_reply_frame(bootp, 5);                      // ACK
    memcpy(vm_ip_now, leased_ip, 4);
    make_canned_frames();
    next_frame = 0;
    dhcp_in_progress = 0;
  }
  if (!rx_valid && !frame_mode) load_next_frame();
}

long ethmodel_read(long a) {
  init();
  if (a >= RX_BASE && a < RX_BASE + WINDOW) return rxbuf[a - RX_BASE];
  if (a >= TX_BASE && a < TX_BASE + WINDOW) return txbuf[a - TX_BASE];
  if (a >= STAGE_BASE && a < STAGE_BASE + STAGE_SIZE) return stage[a - STAGE_BASE];
  switch (a) {
  case ETH_STATUS:
    now_ms += 10;
    if (!rx_valid) load_next_frame();
    if (!rx_valid && !dhcp_in_progress && !tftp_active && next_frame >= nframes) idle_polls++;
    return rx_valid ? RX_VALID : 0;
  case ETH_TIMER_MS: return now_ms & 0x3FFFFFFF;
  case ETH_STATUS_PHY: return PHY_STATUS;
  case ETH_RXLEN: return rx_len;
  default: return 0;
  }
}

void ethmodel_write(long a, long d) {
  init();
  if (a >= TX_BASE && a < TX_BASE + WINDOW) { txbuf[a - TX_BASE] = (uint8_t)d; return; }
  if (a >= STAGE_BASE && a < STAGE_BASE + STAGE_SIZE) { stage[a - STAGE_BASE] = (uint8_t)d; return; }
  switch (a) {
  case ETH_RXLEN: rx_valid = 0; break;             // release the RX window
  case ETH_TXLEN:
    printf("eth: TX %ld", d);
    for (long i = 0; i < d && i < WINDOW; i++) printf(" %02x", txbuf[i]);
    printf("\n");
    dhcp_server(txbuf, (int)d);
    host_arp(txbuf, (int)d);
    tftp_server(txbuf, (int)d);
    if (!rx_valid) load_next_frame();
    break;
  case ETH_BOOT:
    printf("eth: BOOT: staged image %s the file (%ld bytes)\n",
           tftp_data && memcmp(stage, tftp_data, tftp_size) == 0 ? "matches" : "DIFFERS from", tftp_size);
    booted = 1;
    break;
  case LEDS: printf("eth: LEDS %02lx\n", d & 0xFF); break;
  case UART:
    if (d == '\n' || uart_len == (int)sizeof uart_line - 1) {
      uart_line[uart_len] = 0;
      printf("uart: %s\n", uart_line);
      uart_len = 0;
    } else uart_line[uart_len++] = (char)d;
    break;
  default: break;
  }
  fflush(stdout);
}

int ethmodel_done(void) { return booted || (!tftp_active && idle_polls >= IDLE_POLLS_WHEN_DONE); }

void ethmodel_tx_frame(const unsigned char *b, int len) {
  init();
  frame_mode = 1;
  dhcp_server(b, len);
  host_arp(b, len);
  tftp_server(b, len);
}

int ethmodel_rx_frame(unsigned char *buf) {
  init();
  if (!queue_len) return 0;
  frame_t *f = &reply_queue[queue_head];
  queue_head = (queue_head + 1) % QUEUE;
  queue_len--;
  memcpy(buf, f->b, f->len);
  return f->len;
}

int ethmodel_frame(int i, unsigned char *buf) {
  init();
  if (i < 0 || i >= nframes) return 0;
  memcpy(buf, frames[i].b, frames[i].len);
  return frames[i].len;
}
