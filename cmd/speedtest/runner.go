package main

import (
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"sync"
	"time"
)

const (
	// Cloudflare speed test endpoints — no API key required.
	cfBase = "https://speed.cloudflare.com"

	// __down?bytes=N streams exactly N bytes from Cloudflare edge.
	cfDown1MB  = cfBase + "/__down?bytes=1048576"
	cfDown10MB = cfBase + "/__down?bytes=10485760"
	cfDown25MB = cfBase + "/__down?bytes=26214400"

	// __up accepts a POST body; Cloudflare measures server-side receive rate.
	cfUp1MB = cfBase + "/__up"

	cfMeta = cfBase + "/meta"

	pingCount    = 10
	downloadRuns = 3
	uploadRuns   = 3
	uploadSize   = 1 << 20 // 1 MiB per upload run
)

// Runner executes the speed test and emits Progress updates over a channel.
type Runner struct {
	client *http.Client
	mu     sync.Mutex
	done   bool
	result Result
}

// NewRunner creates a Runner with sensible timeouts.
func NewRunner() *Runner {
	return &Runner{
		client: &http.Client{
			Timeout: 60 * time.Second,
			Transport: &http.Transport{
				// Reuse connections for accurate throughput without TCP slow-start
				// overhead on every sample.
				DisableKeepAlives: false,
				MaxIdleConns:      10,
			},
		},
	}
}

// Run executes all phases and returns the final Result synchronously.
// Callers that want incremental progress should use RunWithProgress.
func (r *Runner) Run() (Result, error) {
	var last Result
	ch := make(chan Progress, 64)
	go func() {
		r.RunWithProgress(context.Background(), ch)
	}()
	for p := range ch {
		if p.Err != nil {
			return last, p.Err
		}
		if p.Phase == PhaseDone {
			break
		}
	}
	r.mu.Lock()
	last = r.result
	r.mu.Unlock()
	return last, nil
}

// result is written by RunWithProgress and read by Run.
var _ = (*Runner)(nil) // compile check

// RunWithProgress streams Progress updates to ch and closes it when done.
func (r *Runner) RunWithProgress(ctx context.Context, ch chan<- Progress) {
	defer close(ch)

	send := func(p Progress) {
		select {
		case ch <- p:
		case <-ctx.Done():
		}
	}

	// --- Latency ---
	send(Progress{Phase: PhasePing, PctDone: 0})
	latency, jitter, loss, err := r.measureLatency(ctx, send)
	if err != nil {
		send(Progress{Phase: PhaseError, Err: fmt.Errorf("latency: %w", err)})
		return
	}

	// --- Download ---
	send(Progress{Phase: PhaseDownload, PctDone: 0})
	dlMbps, err := r.measureDownload(ctx, send)
	if err != nil {
		send(Progress{Phase: PhaseError, Err: fmt.Errorf("download: %w", err)})
		return
	}

	// --- Upload ---
	send(Progress{Phase: PhaseUpload, PctDone: 0})
	ulMbps, err := r.measureUpload(ctx, send)
	if err != nil {
		send(Progress{Phase: PhaseError, Err: fmt.Errorf("upload: %w", err)})
		return
	}

	res := Result{
		Timestamp:    time.Now(),
		LatencyMS:    latency,
		JitterMS:     jitter,
		DownloadMbps: dlMbps,
		UploadMbps:   ulMbps,
		Server:       "Cloudflare Edge",
		PacketLoss:   loss,
	}
	r.mu.Lock()
	r.result = res
	r.mu.Unlock()

	send(Progress{Phase: PhaseDone})
}

// result field needs to live on Runner (see Runner struct above).

// measureLatency sends pingCount HEAD requests to cfBase and returns
// (median latency ms, jitter ms, packet-loss %).
func (r *Runner) measureLatency(ctx context.Context, send func(Progress)) (float64, float64, float64, error) {
	var samples []float64
	failed := 0

	for i := 0; i < pingCount; i++ {
		if ctx.Err() != nil {
			return 0, 0, 0, ctx.Err()
		}
		t0 := time.Now()
		req, err := http.NewRequestWithContext(ctx, http.MethodHead, cfBase, nil)
		if err != nil {
			failed++
			continue
		}
		resp, err := r.client.Do(req)
		elapsed := time.Since(t0).Seconds() * 1000
		if err != nil {
			failed++
		} else {
			resp.Body.Close()
			samples = append(samples, elapsed)
		}
		send(Progress{Phase: PhasePing, PctDone: float64(i+1) / float64(pingCount) * 100})
		time.Sleep(50 * time.Millisecond)
	}

	if len(samples) == 0 {
		return 0, 0, 100, fmt.Errorf("all %d pings failed", pingCount)
	}

	sort.Float64s(samples)
	median := samples[len(samples)/2]

	mean := 0.0
	for _, s := range samples {
		mean += s
	}
	mean /= float64(len(samples))

	variance := 0.0
	for _, s := range samples {
		d := s - mean
		variance += d * d
	}
	jitter := math.Sqrt(variance / float64(len(samples)))
	loss := float64(failed) / float64(pingCount) * 100

	return median, jitter, loss, nil
}

// measureDownload downloads progressively larger files and returns the
// highest stable throughput in Mbps.
func (r *Runner) measureDownload(ctx context.Context, send func(Progress)) (float64, error) {
	urls := []string{cfDown1MB, cfDown10MB, cfDown25MB}
	var mbpsSamples []float64

	for i, url := range urls {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		mbps, err := r.downloadURL(ctx, url, func(pct float64) {
			overall := (float64(i) + pct/100) / float64(len(urls)) * 100
			send(Progress{Phase: PhaseDownload, PctDone: overall, InstantMbps: 0})
		})
		if err != nil {
			continue
		}
		mbpsSamples = append(mbpsSamples, mbps)
		send(Progress{Phase: PhaseDownload, PctDone: float64(i+1) / float64(len(urls)) * 100, InstantMbps: mbps})
	}

	if len(mbpsSamples) == 0 {
		return 0, fmt.Errorf("all download samples failed")
	}

	// Return the maximum sample — the highest stable measurement across sizes.
	sort.Float64s(mbpsSamples)
	return mbpsSamples[len(mbpsSamples)-1], nil
}

func (r *Runner) downloadURL(ctx context.Context, url string, progress func(float64)) (float64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}

	t0 := time.Now()
	resp, err := r.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	// Count bytes as we drain to compute throughput accurately.
	var total int64
	buf := make([]byte, 32*1024)
	contentLen := resp.ContentLength
	for {
		n, readErr := resp.Body.Read(buf)
		total += int64(n)
		if contentLen > 0 {
			progress(float64(total) / float64(contentLen) * 100)
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return 0, readErr
		}
	}

	elapsed := time.Since(t0).Seconds()
	if elapsed == 0 {
		return 0, fmt.Errorf("elapsed time was zero")
	}
	mbps := float64(total) * 8 / elapsed / 1e6
	return mbps, nil
}

// measureUpload POSTs random-filled buffers and returns throughput in Mbps.
func (r *Runner) measureUpload(ctx context.Context, send func(Progress)) (float64, error) {
	var mbpsSamples []float64

	for i := 0; i < uploadRuns; i++ {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		mbps, err := r.uploadOnce(ctx)
		if err != nil {
			continue
		}
		mbpsSamples = append(mbpsSamples, mbps)
		send(Progress{
			Phase:       PhaseUpload,
			PctDone:     float64(i+1) / float64(uploadRuns) * 100,
			InstantMbps: mbps,
		})
	}

	if len(mbpsSamples) == 0 {
		return 0, fmt.Errorf("all upload samples failed")
	}

	sort.Float64s(mbpsSamples)
	return mbpsSamples[len(mbpsSamples)-1], nil
}

func (r *Runner) uploadOnce(ctx context.Context) (float64, error) {
	body := newZeroReader(uploadSize)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfUp1MB, body)
	if err != nil {
		return 0, err
	}
	req.ContentLength = int64(uploadSize)
	req.Header.Set("Content-Type", "application/octet-stream")

	t0 := time.Now()
	resp, err := r.client.Do(req)
	elapsed := time.Since(t0).Seconds()
	if err != nil {
		return 0, err
	}
	resp.Body.Close()

	if elapsed == 0 {
		return 0, fmt.Errorf("elapsed time was zero")
	}
	mbps := float64(uploadSize) * 8 / elapsed / 1e6
	return mbps, nil
}

// zeroReader satisfies io.Reader with uploadSize zero bytes.
type zeroReader struct {
	remaining int
}

func newZeroReader(n int) *zeroReader { return &zeroReader{remaining: n} }

func (z *zeroReader) Read(p []byte) (int, error) {
	if z.remaining <= 0 {
		return 0, io.EOF
	}
	n := len(p)
	if n > z.remaining {
		n = z.remaining
	}
	for i := range p[:n] {
		p[i] = 0
	}
	z.remaining -= n
	return n, nil
}
