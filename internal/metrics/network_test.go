package metrics

import "testing"

func TestCollectProxyFromEnvSupportsAllProxy(t *testing.T) {
	env := map[string]string{
		"ALL_PROXY": "socks5://127.0.0.1:7890",
	}
	getenv := func(key string) string {
		return env[key]
	}

	got := CollectProxyFromEnv(getenv)
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

func TestCollectProxyFromScutilOutputPAC(t *testing.T) {
	out := `
<dictionary> {
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://127.0.0.1:6152/proxy.pac
}`
	got := CollectProxyFromScutilOutput(out)
	if !got.Enabled {
		t.Fatalf("expected proxy enabled")
	}
	if got.Type != "PAC" {
		t.Fatalf("expected PAC type, got %s", got.Type)
	}
	if got.Host != "127.0.0.1:6152" {
		t.Fatalf("unexpected host: %s", got.Host)
	}
}

func TestCollectProxyFromScutilOutputHTTPHostPort(t *testing.T) {
	out := `
<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 7890
}`
	got := CollectProxyFromScutilOutput(out)
	if !got.Enabled {
		t.Fatalf("expected proxy enabled")
	}
	if got.Type != "HTTP" {
		t.Fatalf("expected HTTP type, got %s", got.Type)
	}
	if got.Host != "127.0.0.1:7890" {
		t.Fatalf("unexpected host: %s", got.Host)
	}
}
