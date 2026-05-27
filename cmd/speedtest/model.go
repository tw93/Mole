package main

import (
	"encoding/json"
	"fmt"
	"time"
)

// Result holds all measurements from a completed speed test.
type Result struct {
	Timestamp     time.Time `json:"timestamp"`
	LatencyMS     float64   `json:"latency_ms"`      // Median latency in milliseconds
	JitterMS      float64   `json:"jitter_ms"`       // Latency jitter (std-dev) in milliseconds
	DownloadMbps  float64   `json:"download_mbps"`   // Download throughput in Mbps
	UploadMbps    float64   `json:"upload_mbps"`     // Upload throughput in Mbps
	Server        string    `json:"server"`          // Test server used
	PacketLoss    float64   `json:"packet_loss_pct"` // Packet loss estimate (0-100)
}

// JSON serialises the Result as indented JSON.
func (r Result) JSON() string {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	return string(b)
}

// Phase tracks which measurement is currently running.
type Phase int

const (
	PhaseIdle Phase = iota
	PhasePing
	PhaseDownload
	PhaseUpload
	PhaseDone
	PhaseError
)

func (p Phase) String() string {
	switch p {
	case PhaseIdle:
		return "idle"
	case PhasePing:
		return "latency"
	case PhaseDownload:
		return "download"
	case PhaseUpload:
		return "upload"
	case PhaseDone:
		return "done"
	case PhaseError:
		return "error"
	default:
		return "unknown"
	}
}

// Progress carries incremental updates from the Runner to the TUI.
type Progress struct {
	Phase       Phase
	PctDone     float64 // 0-100 within the current phase
	InstantMbps float64 // Most-recent throughput sample (download or upload)
	Err         error
}
