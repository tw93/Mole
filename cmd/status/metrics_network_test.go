package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	gopsutilnet "github.com/shirou/gopsutil/v4/net"
)

func TestCollectProxyFromEnvSupportsAllProxy(t *testing.T) {
	env := map[string]string{
		"ALL_PROXY": "socks5://127.0.0.1:7890",
	}
	getenv := func(key string) string {
		return env[key]
	}

	got := collectProxyFromEnv(getenv)
	if !got.Enabled {
		t.Fatalf("expected proxy enabled")
	}
	if got.Type != "SOCKS" {
		t.Fatalf("expected SOCKS type, got %s", got.Type)
	}
	if got.Host != "127.0.0.1:7890" {
		t.Fatalf("unexpected host: %s", got.Host)
	}
}

func TestCollectIOCountersSafelyRecoversPanic(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		panic("boom")
	}
	t.Cleanup(func() { ioCountersFunc = original })

	stats, err := collectIOCountersSafely()
	if err == nil {
		t.Fatalf("expected error from panic recovery")
	}
	if !strings.Contains(err.Error(), "panic collecting network counters") {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(stats) != 0 {
		t.Fatalf("expected empty stats when panic recovered")
	}
}

func TestCollectIOCountersSafelyReturnsData(t *testing.T) {
	original := ioCountersFunc
	want := []gopsutilnet.IOCountersStat{
		{Name: "en0", BytesRecv: 1, BytesSent: 2},
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return want, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	got, err := collectIOCountersSafely()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 || got[0].Name != "en0" {
		t.Fatalf("unexpected stats: %+v", got)
	}
}

func TestCollectNetworkFirstSampleReturnsZeroRateInterfaces(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{
			{Name: "en0", BytesRecv: 1000, BytesSent: 2000},
		}, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	c := &Collector{}
	got := c.collectNetwork(time.Now())
	if len(got) != 1 {
		t.Fatalf("expected first sample to render one interface, got %+v", got)
	}
	if got[0].RxRateMBs != 0 || got[0].TxRateMBs != 0 {
		t.Fatalf("expected first sample zero rates, got %+v", got[0])
	}
	if len(c.rxHistoryBuf.Slice()) != 1 || len(c.txHistoryBuf.Slice()) != 1 {
		t.Fatalf("expected history to be seeded on first sample")
	}
}

func TestCollectNetworkUsesPrimedCountersForInitialRates(t *testing.T) {
	original := ioCountersFunc
	calls := 0
	samples := [][]gopsutilnet.IOCountersStat{
		{{Name: "en0", BytesRecv: 1024 * 1024, BytesSent: 0}},
		{{Name: "en0", BytesRecv: 2 * 1024 * 1024, BytesSent: 512 * 1024}},
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		if calls >= len(samples) {
			return samples[len(samples)-1], nil
		}
		got := samples[calls]
		calls++
		return got, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	c := NewCollector(ProcessWatchOptions{})
	got := c.collectNetwork(c.lastNetAt.Add(time.Second))
	if len(got) != 1 {
		t.Fatalf("expected one interface, got %+v", got)
	}
	if got[0].RxRateMBs != 1.0 {
		t.Fatalf("expected 1 MB/s down, got %v", got[0].RxRateMBs)
	}
	if got[0].TxRateMBs != 0.5 {
		t.Fatalf("expected 0.5 MB/s up, got %v", got[0].TxRateMBs)
	}
}

func TestCollectNetworkClampsCounterReset(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{
			{Name: "en0", BytesRecv: 10, BytesSent: 20},
		}, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	base := time.Now()
	c := &Collector{
		prevNet: map[string]gopsutilnet.IOCountersStat{
			"en0": {Name: "en0", BytesRecv: 1024 * 1024, BytesSent: 1024 * 1024},
		},
		lastNetAt:    base,
		rxHistoryBuf: NewRingBuffer(NetworkHistorySize),
		txHistoryBuf: NewRingBuffer(NetworkHistorySize),
	}

	got := c.collectNetwork(base.Add(time.Second))
	if len(got) != 1 {
		t.Fatalf("expected one interface, got %+v", got)
	}
	if got[0].RxRateMBs != 0 || got[0].TxRateMBs != 0 {
		t.Fatalf("expected reset counters to clamp to zero, got %+v", got[0])
	}
}

func TestTunnelInterfaceIsNotReportedAsAProxy(t *testing.T) {
	// A machine with no configured proxy but an active tun (iCloud Private
	// Relay, a corporate VPN, or a TUN-mode client) must not be told it has a
	// proxy. The reading is still surfaced, just honestly labelled.
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{
			{Name: "en0", BytesRecv: 100},
			{Name: "tun4", BytesRecv: 20, BytesSent: 30},
		}, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	got := collectProxyFromTunInterfaces()
	if !got.Enabled || !got.IsTunnel || got.Type != "TUN" || got.Host != "tun4" {
		t.Fatalf("unexpected tunnel status: %+v", got)
	}
	card := renderNetworkCard(
		[]NetworkStatus{{Name: "en0", IP: "192.0.2.10"}},
		NetworkHistory{}, got, 40,
	)
	rendered := strings.Join(card.lines, "\n")
	if !strings.Contains(rendered, "Tunnel") || strings.Contains(rendered, "Proxy Tunnel") {
		t.Fatalf("tunnel must be rendered without a proxy claim: %q", rendered)
	}
}

func TestTunnelHintDoesNotExpandProxyJSONContract(t *testing.T) {
	encoded, err := json.Marshal(ProxyStatus{
		Enabled:  true,
		Type:     "TUN",
		Host:     "tun4",
		IsTunnel: true,
	})
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	const want = `{"enabled":true,"type":"TUN","host":"tun4"}`
	if string(encoded) != want {
		t.Fatalf("proxy JSON contract changed: got %s, want %s", encoded, want)
	}
}

func TestCollectNetworkDefaultTunnel(t *testing.T) {
	originalIO, originalRoute := ioCountersFunc, defaultRouteFunc
	t.Cleanup(func() { ioCountersFunc, defaultRouteFunc = originalIO, originalRoute })
	const mb = 1024 * 1024
	now := time.Now()
	route := "tun4"
	routeErr := false
	defaultRouteFunc = func() string {
		if routeErr {
			return ""
		}
		return route
	}
	names := []string{"en0", "en4", "en6", "tun4", "ppp0", "ipsec0", "tun9"}
	counters := make([]gopsutilnet.IOCountersStat, len(names))
	for i, name := range names {
		counters[i] = gopsutilnet.IOCountersStat{Name: name, BytesRecv: 100 * mb, BytesSent: 100 * mb}
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return append([]gopsutilnet.IOCountersStat(nil), counters...), nil
	}
	c := &Collector{prevNet: make(map[string]gopsutilnet.IOCountersStat), cachedNetIPs: map[string]string{"en0": "192.0.2.1"}, lastNetIPAt: now}
	c.primeNetworkCounters(now)
	for _, step := range []struct {
		route  string
		fail   bool
		wantRx float64
	}{
		{"tun4", false, 2}, {"ppp0", false, 3}, {"ipsec0", false, 4}, {"en0", false, 30}, {"tun4", true, 30},
	} {
		route, routeErr = step.route, step.fail
		for i := range counters {
			rate := uint64(10)
			if i >= 3 {
				rate = uint64(i - 1)
			}
			counters[i].BytesRecv += rate * mb
			counters[i].BytesSent += mb
		}
		now = now.Add(time.Second)
		got := c.collectNetworkFull(now)
		wantTunnel := route != "en0" && !routeErr
		found := false
		for _, n := range got {
			if !strings.HasPrefix(n.Name, "en") {
				if !wantTunnel || n.Name != route {
					t.Fatalf("unexpected idle/non-default tunnel: %+v", got)
				}
				found = true
			}
		}
		if found != wantTunnel {
			t.Fatalf("default route %s missing from counters: %+v", route, got)
		}
		rx := c.rxHistoryBuf.Slice()
		if rx[len(rx)-1] != step.wantRx {
			t.Fatalf("route %s: history = %v, want %v", route, rx, step.wantRx)
		}
		card := renderNetworkCard(got, NetworkHistory{}, ProxyStatus{}, 40)
		if !strings.Contains(card.lines[0], formatRate(step.wantRx)) {
			t.Fatalf("card and history disagree: %v", card.lines)
		}
		encoded, err := json.Marshal(got)
		if err != nil {
			t.Fatal(err)
		}
		var rows []map[string]any
		if err := json.Unmarshal(encoded, &rows); err != nil {
			t.Fatal(err)
		}
		for _, row := range rows {
			if len(row) != 4 {
				t.Fatalf("network JSON shape changed: %s", encoded)
			}
		}
	}
}

func TestCollectNetworkKeepsIdleDefaultInterface(t *testing.T) {
	original := ioCountersFunc
	t.Cleanup(func() { ioCountersFunc = original })
	const mb = 1024 * 1024
	// Kernel order on Apple silicon: Thunderbolt ports come before Wi-Fi en0.
	names := []string{"en4", "en5", "en6", "en1", "en0"}
	counters := make([]gopsutilnet.IOCountersStat, len(names))
	for i, name := range names {
		counters[i] = gopsutilnet.IOCountersStat{Name: name, BytesRecv: 100 * mb, BytesSent: 100 * mb}
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return append([]gopsutilnet.IOCountersStat(nil), counters...), nil
	}
	now := time.Now()
	c := &Collector{prevNet: make(map[string]gopsutilnet.IOCountersStat), defaultNetInterface: "en0", cachedNetIPs: map[string]string{}, lastNetIPAt: now}
	c.primeNetworkCounters(now)
	names3 := func(got []NetworkStatus) string {
		var out []string
		for _, n := range got {
			out = append(out, n.Name)
		}
		return strings.Join(out, ",")
	}

	// Every interface idle: tie order is unspecified, but the routed one stays.
	now = now.Add(time.Second)
	if got := c.collectNetwork(now); len(got) != 3 || !strings.Contains(","+names3(got)+",", ",en0,") {
		t.Fatalf("idle routed interface dropped: %s", names3(got))
	}
	// Three busier interfaces keep their order; the routed one still shows.
	for i := range 3 {
		counters[i].BytesRecv += uint64(3-i) * mb
	}
	now = now.Add(time.Second)
	if got := names3(c.collectNetwork(now)); got != "en4,en5,en0" {
		t.Fatalf("busy interfaces pushed out the routed one: %s", got)
	}
}

func TestNetworkCardShowsRoutedInterfaceIP(t *testing.T) {
	ipLine := func(rows []NetworkStatus) string {
		card := renderNetworkCard(rows, NetworkHistory{}, ProxyStatus{}, 40)
		return card.lines[len(card.lines)-1]
	}
	wifi := NetworkStatus{Name: "en0", IP: "192.0.2.10"}
	ethernet := NetworkStatus{Name: "en7", IP: "198.51.100.7"}

	routedEthernet := ethernet
	routedEthernet.defaultRoute = true
	if got := ipLine([]NetworkStatus{wifi, routedEthernet}); got != "198.51.100.7" {
		t.Fatalf("routed Ethernet IP not shown: %q", got)
	}
	if got := ipLine([]NetworkStatus{routedEthernet}); got != "198.51.100.7" {
		t.Fatalf("routed adapter without en0 shows no IP: %q", got)
	}
	// A routed tunnel's address is not the LAN IP; keep en0.
	tunnel := NetworkStatus{Name: "tun4", IP: "100.64.0.2", defaultRoute: true, defaultTunnel: true}
	if got := ipLine([]NetworkStatus{tunnel, wifi}); got != "192.0.2.10" {
		t.Fatalf("routed tunnel replaced the LAN IP: %q", got)
	}
	// Unknown route keeps the en0 fallback.
	if got := ipLine([]NetworkStatus{ethernet, wifi}); got != "192.0.2.10" {
		t.Fatalf("en0 fallback lost: %q", got)
	}
}

func TestCollectNetworkMarksRoutedInterface(t *testing.T) {
	original := ioCountersFunc
	t.Cleanup(func() { ioCountersFunc = original })
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{{Name: "en0"}, {Name: "en7"}}, nil
	}
	now := time.Now()
	c := &Collector{
		prevNet:             make(map[string]gopsutilnet.IOCountersStat),
		defaultNetInterface: "en7",
		cachedNetIPs:        map[string]string{"en0": "192.0.2.10", "en7": "198.51.100.7"},
		lastNetIPAt:         now,
	}
	c.primeNetworkCounters(now)
	got := c.collectNetwork(now.Add(time.Second))
	card := renderNetworkCard(got, NetworkHistory{}, ProxyStatus{}, 40)
	if line := card.lines[len(card.lines)-1]; line != "198.51.100.7" {
		t.Fatalf("collected rows lost the routed interface: %+v, IP line %q", got, line)
	}
}

func TestIsNoiseInterfaceSkipsContainerAndVMPlumbing(t *testing.T) {
	for name, want := range map[string]bool{
		"lo": true, "docker0": true, "veth3a1b2c": true, "br-1f2e3d4c5b6a": true,
		"virbr0": true, "vnet12": true,
		"eth0": false, "enp3s0": false, "wlan0": false, "wlp2s0": false, "tailscale0": false, "wg0": false,
	} {
		if got := isNoiseInterface(name); got != want {
			t.Fatalf("isNoiseInterface(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestIsTunnelInterfaceLinuxNames(t *testing.T) {
	for name, want := range map[string]bool{
		"tun0": true, "wg0": true, "tailscale0": true, "ppp0": true,
		"eth0": false, "wlan0": false, "docker0": false,
	} {
		if got := isTunnelInterface(name); got != want {
			t.Fatalf("isTunnelInterface(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestParseDefaultRouteInterfacePicksLowestMetricUpRoute(t *testing.T) {
	raw := "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" +
		"wlan0\t00000000\t0100A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n" +
		"eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n" +
		"eth1\t00000000\t0100A8C0\t0002\t0\t0\t50\t00000000\t0\t0\t0\n" + // not RTF_UP
		"eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n" // on-link subnet, not default
	if got := parseDefaultRouteInterface(raw); got != "eth0" {
		t.Fatalf("parseDefaultRouteInterface() = %q, want eth0", got)
	}
	if got := parseDefaultRouteInterface("Iface\tDestination\n"); got != "" {
		t.Fatalf("parseDefaultRouteInterface(no routes) = %q, want empty", got)
	}
}
