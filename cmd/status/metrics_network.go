package main

import (
	"fmt"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/net"
)

var ioCountersFunc = net.IOCounters

const (
	minNetworkSampleInterval = 100 * time.Millisecond
	networkIPCacheTTL        = 10 * time.Second
)

// noiseInterfacePrefixes are loopback and container or VM plumbing: Docker's
// bridge and per-container veth pairs, user-defined bridges (br-<id>), libvirt
// virbr and vnet taps. They carry traffic that the physical interface already
// counted, or none a person looks at.
var noiseInterfacePrefixes = [...]string{"lo", "docker", "veth", "br-", "virbr", "vnet", "cni", "flannel"}

func collectIOCountersSafely() (stats []net.IOCountersStat, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic collecting network counters: %v", r)
		}
	}()
	return ioCountersFunc(true)
}

func (c *Collector) primeNetworkCounters(now time.Time) {
	stats, err := collectIOCountersSafely()
	if err != nil {
		return
	}
	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}
}

// Only full collection re-reads the route table; fast frames reuse the latest route.
func (c *Collector) collectNetworkFull(now time.Time) []NetworkStatus {
	c.defaultNetInterface = defaultRouteFunc()
	return c.collectNetwork(now)
}

func (c *Collector) collectNetwork(now time.Time) []NetworkStatus {
	if c.prevNet == nil {
		c.prevNet = make(map[string]net.IOCountersStat)
	}
	if c.rxHistoryBuf == nil {
		c.rxHistoryBuf = NewRingBuffer(NetworkHistorySize)
	}
	if c.txHistoryBuf == nil {
		c.txHistoryBuf = NewRingBuffer(NetworkHistorySize)
	}

	stats, err := collectIOCountersSafely()
	if err != nil {
		// Restricted environments can hide /proc/net/dev.
		// Degrade gracefully to keep status output available.
		c.rxHistoryBuf.Add(0)
		c.txHistoryBuf.Add(0)
		return nil
	}

	// Map interface IPs.
	ifAddrs := c.getInterfaceIPsCached(now)
	defaultInterface := c.defaultNetInterface

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for _, s := range stats {
			c.prevNet[s.Name] = s
		}
	}

	elapsed := now.Sub(c.lastNetAt).Seconds()
	if elapsed < minNetworkSampleInterval.Seconds() {
		elapsed = minNetworkSampleInterval.Seconds()
	}

	var result []NetworkStatus
	for _, cur := range stats {
		if (isNoiseInterface(cur.Name) || isTunnelInterface(cur.Name)) && cur.Name != defaultInterface {
			continue
		}
		prev, ok := c.prevNet[cur.Name]
		if !ok {
			continue
		}
		rx := float64(counterDelta(cur.BytesRecv, prev.BytesRecv)) / 1024.0 / 1024.0 / elapsed
		tx := float64(counterDelta(cur.BytesSent, prev.BytesSent)) / 1024.0 / 1024.0 / elapsed
		result = append(result, NetworkStatus{
			Name:          cur.Name,
			RxRateMBs:     rx,
			TxRateMBs:     tx,
			IP:            ifAddrs[cur.Name],
			defaultTunnel: cur.Name == defaultInterface && isTunnelInterface(cur.Name),
			defaultRoute:  cur.Name == defaultInterface,
		})
	}

	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}

	sort.Slice(result, func(i, j int) bool {
		// Keep the routed tunnel visible even when its physical carrier is busier.
		if result[i].defaultTunnel != result[j].defaultTunnel {
			return result[i].defaultTunnel
		}
		return result[i].RxRateMBs+result[i].TxRateMBs > result[j].RxRateMBs+result[j].TxRateMBs
	})
	if len(result) > 3 {
		// Idle interfaces tie at zero and the kernel lists Thunderbolt ports
		// before Wi-Fi en0, so an idle routed interface could fall off the cap.
		for i := 3; i < len(result); i++ {
			if result[i].Name == defaultInterface {
				result[2] = result[i]
				break
			}
		}
		result = result[:3]
	}

	totalRx, totalTx := networkTotals(result)

	// Update history using the global/aggregated stats
	c.rxHistoryBuf.Add(totalRx)
	c.txHistoryBuf.Add(totalTx)

	return result
}

// defaultRouteFunc is replaceable so tests can script the routing table.
var defaultRouteFunc = defaultRouteInterface

// The IPv4 default route identifies the active tunnel without guessing from
// cumulative bytes on idle system tunnels. A failed read keeps physical rates.
func defaultRouteInterface() string {
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return ""
	}
	return parseDefaultRouteInterface(string(data))
}

// parseDefaultRouteInterface picks the up interface with destination 0.0.0.0
// and mask 0.0.0.0 that has the lowest metric. Columns:
// Iface Destination Gateway Flags RefCnt Use Metric Mask ...
func parseDefaultRouteInterface(raw string) string {
	best, bestMetric := "", -1
	for line := range strings.Lines(raw) {
		f := strings.Fields(line)
		if len(f) < 8 || f[1] != "00000000" || f[7] != "00000000" {
			continue
		}
		flags, err := strconv.ParseUint(f[3], 16, 32)
		if err != nil || flags&0x1 == 0 { // RTF_UP
			continue
		}
		metric, err := strconv.Atoi(f[6])
		if err != nil {
			continue
		}
		if bestMetric < 0 || metric < bestMetric {
			best, bestMetric = f[0], metric
		}
	}
	return best
}

func isTunnelInterface(name string) bool {
	for _, prefix := range []string{"tun", "wg", "tailscale", "ppp", "ipsec"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

// Tunnel and carrier counters describe overlapping traffic. Keep both as
// interface rows, but use the routed tunnel for the card and history totals.
func networkTotals(stats []NetworkStatus) (rx, tx float64) {
	for _, n := range stats {
		if n.defaultTunnel {
			return n.RxRateMBs, n.TxRateMBs
		}
		rx += n.RxRateMBs
		tx += n.TxRateMBs
	}
	return rx, tx
}

func (c *Collector) getInterfaceIPsCached(now time.Time) map[string]string {
	if c.cachedNetIPs != nil && now.Sub(c.lastNetIPAt) < networkIPCacheTTL {
		return c.cachedNetIPs
	}
	c.cachedNetIPs = getInterfaceIPs()
	c.lastNetIPAt = now
	return c.cachedNetIPs
}

func getInterfaceIPs() map[string]string {
	result := make(map[string]string)
	ifaces, err := net.Interfaces()
	if err != nil {
		return result
	}
	for _, iface := range ifaces {
		for _, addr := range iface.Addrs {
			// IPv4 only.
			if strings.Contains(addr.Addr, ".") && !strings.HasPrefix(addr.Addr, "127.") {
				ip, _, _ := strings.Cut(addr.Addr, "/")
				result[iface.Name] = ip
				break
			}
		}
	}
	return result
}

func isNoiseInterface(name string) bool {
	lower := strings.ToLower(name)
	for _, prefix := range noiseInterfacePrefixes {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectProxy() ProxyStatus {
	if proxy := collectProxyFromEnv(os.Getenv); proxy.Enabled {
		return proxy
	}

	if proxy := collectProxyFromTunInterfaces(); proxy.Enabled {
		return proxy
	}

	return ProxyStatus{Enabled: false}
}

func collectProxyFromEnv(getenv func(string) string) ProxyStatus {
	// Include ALL_PROXY for users running proxy tools that only export a single variable.
	envKeys := []string{
		"https_proxy", "HTTPS_PROXY",
		"http_proxy", "HTTP_PROXY",
		"all_proxy", "ALL_PROXY",
	}
	for _, key := range envKeys {
		val := strings.TrimSpace(getenv(key))
		if val == "" {
			continue
		}

		proxyType := "HTTP"
		lower := strings.ToLower(val)
		if strings.HasPrefix(lower, "socks") {
			proxyType = "SOCKS"
		}

		host := parseProxyHost(val)
		if host == "" {
			host = val
		}
		return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
	}

	return ProxyStatus{Enabled: false}
}

func collectProxyFromTunInterfaces() ProxyStatus {
	stats, err := collectIOCountersSafely()
	if err != nil {
		return ProxyStatus{Enabled: false}
	}

	var activeTun []string
	for _, s := range stats {
		lower := strings.ToLower(s.Name)
		if strings.HasPrefix(lower, "tun") {
			if s.BytesRecv+s.BytesSent > 0 {
				activeTun = append(activeTun, s.Name)
			}
		}
	}
	if len(activeTun) == 0 {
		return ProxyStatus{Enabled: false}
	}
	sort.Strings(activeTun)
	host := activeTun[0]
	if len(activeTun) > 1 {
		host = activeTun[0] + "+"
	}
	// Reported as a tunnel, never as a proxy. This branch is only reached when
	// no proxy is configured in the environment, which is exactly the case
	// where an active `tun` is most likely a VPN. Calling that "Proxy TUN"
	// told users something false about a machine that has no proxy at all.
	// Keep the existing JSON type value for automation consumers. IsTunnel is
	// the presentation hint that lets the terminal UI use an honest label.
	return ProxyStatus{Enabled: true, Type: "TUN", Host: host, IsTunnel: true}
}

func parseProxyHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	target := raw
	if !strings.Contains(target, "://") {
		target = "http://" + target
	}
	parsed, err := url.Parse(target)
	if err != nil {
		return ""
	}
	host := parsed.Host
	if host == "" {
		return ""
	}
	return strings.TrimPrefix(host, "@")
}

func joinHostPort(host, port string) string {
	host = strings.TrimSpace(host)
	port = strings.TrimSpace(port)
	if host == "" {
		return ""
	}
	if port == "" {
		return host
	}
	if _, err := strconv.Atoi(port); err != nil {
		return host
	}
	return host + ":" + port
}
