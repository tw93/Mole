//go:build windows

package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// protectedTrees are refused with everything below them, on every volume.
var protectedTrees = []string{
	`\Windows`,
	`\Program Files`,
	`\Program Files (x86)`,
	`\ProgramData`,
	`\Users\Default`,
	`\Users\Public`,
	`\Recovery`,
	`\System Volume Information`,
	`\$Recycle.Bin`,
	`\Config.Msi`,
	`\PerfLogs`,
	`\Boot`,
	`\Documents and Settings`,
	`\$WinREAgent`,
}

// volumeRootFiles are the paging files Windows keeps at the root of any volume.
var volumeRootFiles = []string{`pagefile.sys`, `hiberfil.sys`, `swapfile.sys`}

// protectedTreeEnvVars name system folders that may live away from their
// default location; each is refused with everything below it.
var protectedTreeEnvVars = []string{
	"WINDIR",
	"SystemRoot",
	"ProgramFiles",
	"ProgramFiles(x86)",
	"ProgramW6432",
	"ProgramData",
}

// isProtectedPath reports whether Analyze must refuse to delete path. It fails
// closed: a path that cannot be resolved counts as protected.
func isProtectedPath(path string) bool {
	if strings.TrimSpace(path) == "" {
		return true
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return true
	}
	absPath = strings.ToLower(absPath)

	// A GLOBALROOT device path reaches a volume through the object namespace, so
	// the components after it are not folders on that volume. Refuse it.
	if strings.HasSuffix(filepath.VolumeName(absPath), `\globalroot`) {
		return true
	}

	// Match on the path inside its volume, so C:\, \\server\share\, \\?\C:\ and
	// \\?\Volume{GUID}\ spellings of the same location are protected alike.
	rel := volumeRelativePath(absPath)

	// The volume root itself.
	if rel == `\` {
		return true
	}

	for _, protected := range protectedTrees {
		protectedRel := strings.ToLower(protected)
		if rel == protectedRel || strings.HasPrefix(rel, protectedRel+`\`) {
			return true
		}
	}

	// One entry at a volume's root: a paging file on any volume, and anything at
	// all on the system drive's first level, which holds nothing of the user's.
	if rest := rel[1:]; !strings.Contains(rest, `\`) {
		if slices.Contains(volumeRootFiles, rest) || onSystemDrive(absPath) {
			return true
		}
	}

	// \Users and every profile root directly below it, the user's own included.
	if rel == `\users` {
		return true
	}
	if rest, ok := strings.CutPrefix(rel, `\users\`); ok && rest != "" && !strings.Contains(rest, `\`) {
		return true
	}

	for _, name := range protectedTreeEnvVars {
		if isAtOrBelow(absPath, os.Getenv(name)) {
			return true
		}
	}

	// The profile root, wherever it lives, and Docker Desktop's live state.
	for _, home := range []string{os.Getenv("USERPROFILE"), userHomeDir()} {
		if home != "" && strings.EqualFold(strings.TrimRight(absPath, `\`), strings.TrimRight(filepath.Clean(home), `\`)) {
			return true
		}
	}
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" && isAtOrBelow(absPath, filepath.Join(localAppData, "Docker")) {
		return true
	}

	return isUserHead(absPath)
}

// profileFolders are the folders Windows creates in a profile.
var profileFolders = []string{"desktop", "documents", "downloads", "pictures", "videos", "music", "appdata"}

// oneDriveEnvVars name the personal and work OneDrive sync roots, wherever they live.
var oneDriveEnvVars = []string{"OneDrive", "OneDriveConsumer", "OneDriveCommercial"}

// isUserHead reports whether a lowercased absolute path is the head of the
// user's own tree, which Analyze never deletes: the folders Windows creates in
// the profile, AppData's Local, Roaming and LocalLow, a OneDrive root (a
// deletion there syncs to every device) and the Mole app's own folders. Only
// the folder itself is refused, except Mole's, refused whole: what a user keeps
// inside Documents or a OneDrive folder can still be deleted.
func isUserHead(lowerAbsPath string) bool {
	trimmed := strings.TrimRight(lowerAbsPath, `\`)
	same := func(root string) bool {
		if strings.TrimSpace(root) == "" {
			return false
		}
		clean, err := filepath.Abs(root)
		return err == nil && trimmed == strings.TrimRight(strings.ToLower(clean), `\`)
	}
	for _, home := range []string{os.Getenv("USERPROFILE"), userHomeDir()} {
		if home == "" {
			continue
		}
		for _, name := range profileFolders {
			if same(filepath.Join(home, name)) {
				return true
			}
		}
		for _, store := range []string{"Local", "Roaming", "LocalLow"} {
			if same(filepath.Join(home, "AppData", store)) {
				return true
			}
		}
		if cleanHome, err := filepath.Abs(home); err == nil && strings.EqualFold(filepath.Dir(trimmed), strings.TrimRight(cleanHome, `\`)) {
			if name := filepath.Base(trimmed); name == "onedrive" || strings.HasPrefix(name, "onedrive - ") {
				return true
			}
		}
	}
	for _, name := range oneDriveEnvVars {
		if same(os.Getenv(name)) {
			return true
		}
	}
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		for _, own := range []string{"Mole", "Tw93.Mole"} {
			if isAtOrBelow(lowerAbsPath, filepath.Join(localAppData, own)) {
				return true
			}
		}
	}
	return false
}

// onSystemDrive reports whether a lowercased absolute path is on the system
// drive. A share is not; a volume GUID or device spelling cannot be told apart
// from it here, so it counts as the system drive, as does a missing SystemDrive.
func onSystemDrive(lowerAbsPath string) bool {
	volume := strings.TrimPrefix(filepath.VolumeName(lowerAbsPath), `\\?\`)
	if strings.HasPrefix(volume, `\\`) || strings.HasPrefix(volume, `unc\`) {
		return false
	}
	system := strings.ToLower(strings.TrimSpace(os.Getenv("SystemDrive")))
	if system == "" || len(volume) != 2 || volume[1] != ':' {
		return true
	}
	return volume == system
}

func userHomeDir() string {
	home, _ := os.UserHomeDir()
	return home
}

// isAtOrBelow compares a lowercased absolute path with root, case-insensitively.
func isAtOrBelow(lowerAbsPath, root string) bool {
	if strings.TrimSpace(root) == "" {
		return false
	}
	cleanRoot, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	cleanRoot = strings.TrimRight(strings.ToLower(cleanRoot), `\`)
	trimmed := strings.TrimRight(lowerAbsPath, `\`)
	return trimmed == cleanRoot || strings.HasPrefix(trimmed, cleanRoot+`\`)
}

// volumeRelativePath returns an absolute, lowercased path without its volume
// (`c:`, `\\server\share`, `\\?\c:`, `\\?\volume{guid}`), starting with a separator.
func volumeRelativePath(absPath string) string {
	p := absPath
	// Before Go 1.27, VolumeName counts host and share only for \\.\UNC\, so
	// \\?\UNC\host\share\x would yield \host\share\x. Spell it as plain UNC.
	for _, prefix := range []string{`\\?\unc\`, `\\.\unc\`, `\??\unc\`} {
		if strings.HasPrefix(p, prefix) {
			p = `\\` + p[len(prefix):]
			break
		}
	}
	rel := strings.TrimRight(p[len(filepath.VolumeName(p)):], `\`)
	if !strings.HasPrefix(rel, `\`) {
		rel = `\` + rel
	}
	return rel
}
