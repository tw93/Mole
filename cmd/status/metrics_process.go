package main

import (
	"context"
	"fmt"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

func collectProcesses() ([]ProcessInfo, error) {
	if runtime.GOOS != "darwin" {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "ps", "-Aceo", "pid=,ppid=,pcpu=,pmem=,comm=", "-r")
	if err != nil {
		return nil, err
	}
	return parseProcessOutput(out), nil
}

func parseProcessOutput(raw string) []ProcessInfo {
	var procs []ProcessInfo
	for line := range strings.Lines(strings.TrimSpace(raw)) {
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}

		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 0 {
			continue
		}
		ppid, _ := strconv.Atoi(fields[1])
		cpuVal, err := strconv.ParseFloat(fields[2], 64)
		if err != nil {
			continue
		}
		memVal, err := strconv.ParseFloat(fields[3], 64)
		if err != nil {
			continue
		}

		command := strings.Join(fields[4:], " ")
		if command == "" {
			continue
		}
		name := command
		// Strip path from command name.
		if idx := strings.LastIndex(name, "/"); idx >= 0 {
			name = name[idx+1:]
		}
		procs = append(procs, ProcessInfo{
			PID:     pid,
			PPID:    ppid,
			Name:    name,
			Command: command,
			CPU:     cpuVal,
			Memory:  memVal,
		})
	}
	return procs
}

func topProcesses(processes []ProcessInfo, limit int) []ProcessInfo {
	if limit <= 0 || len(processes) == 0 {
		return nil
	}

	procs := make([]ProcessInfo, len(processes))
	copy(procs, processes)
	sort.Slice(procs, func(i, j int) bool {
		if procs[i].CPU != procs[j].CPU {
			return procs[i].CPU > procs[j].CPU
		}
		if procs[i].Memory != procs[j].Memory {
			return procs[i].Memory > procs[j].Memory
		}
		return procs[i].PID < procs[j].PID
	})

	if len(procs) > limit {
		procs = procs[:limit]
	}
	return procs
}

func formatProcessLabel(proc ProcessInfo) string {
	if proc.Name != "" {
		return fmt.Sprintf("%s (%d)", proc.Name, proc.PID)
	}
	return fmt.Sprintf("pid %d", proc.PID)
}
