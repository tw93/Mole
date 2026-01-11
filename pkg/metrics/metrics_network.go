package metrics

import (
	"context"
	"os"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/net"
)

func (c *Collector) collectNetwork(now time.Time) ([]NetworkStatus, error) {
	stats, err := net.IOCounters(true)
	if err != nil {
		return nil, err
	}

	// Map interface IPs.
	ifAddrs := getInterfaceIPs()

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for _, s := range stats {
			c.prevNet[s.Name] = s
		}
		return nil, nil
	}

	elapsed := now.Sub(c.lastNetAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	var result []NetworkStatus
	for _, cur := range stats {
		if isNoiseInterface(cur.Name) {
			continue
		}
		prev, ok := c.prevNet[cur.Name]
		if !ok {
			continue
		}
		rx := float64(cur.BytesRecv-prev.BytesRecv) / 1024.0 / 1024.0 / elapsed
		tx := float64(cur.BytesSent-prev.BytesSent) / 1024.0 / 1024.0 / elapsed
		if rx < 0 {
			rx = 0
		}
		if tx < 0 {
			tx = 0
		}
		result = append(result, NetworkStatus{
			Name:      cur.Name,
			RxRateMBs: rx,
			TxRateMBs: tx,
			IP:        ifAddrs[cur.Name],
		})
	}

	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].RxRateMBs+result[i].TxRateMBs > result[j].RxRateMBs+result[j].TxRateMBs
	})
	if len(result) > 3 {
		result = result[:3]
	}

	return result, nil
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
				ip := strings.Split(addr.Addr, "/")[0]
				result[iface.Name] = ip
				break
			}
		}
	}
	return result
}

func isNoiseInterface(name string) bool {
	lower := strings.ToLower(name)
	noiseList := []string{"lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"}
	for _, prefix := range noiseList {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectProxy() ProxyStatus {
	// Check environment variables first.
	for _, env := range []string{"https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"} {
		if val := os.Getenv(env); val != "" {
			proxyType := "HTTP"
			if strings.HasPrefix(val, "socks") {
				proxyType = "SOCKS"
			}
			// Extract host.
			host := val
			if strings.Contains(host, "://") {
				host = strings.SplitN(host, "://", 2)[1]
			}
			if idx := strings.Index(host, "@"); idx >= 0 {
				host = host[idx+1:]
			}
			return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
		}
	}

	// macOS: check system proxy via scutil.
	if runtime.GOOS == "darwin" {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel()
		out, err := runCmd(ctx, "scutil", "--proxy")
		if err == nil {
			if strings.Contains(out, "HTTPEnable : 1") || strings.Contains(out, "HTTPSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "System", Host: "System Proxy"}
			}
			if strings.Contains(out, "SOCKSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "SOCKS", Host: "System Proxy"}
			}
		}
	}

	return ProxyStatus{Enabled: false}
}
