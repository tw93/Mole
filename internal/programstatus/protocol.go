package programstatus

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const prefix = "\x1b]7501;"
const terminator = "\x1b\\"

type State string

const (
	StateIdle    State = "idle"
	StateWorking State = "working"
	StateDone    State = "done"
	StateBlocked State = "blocked"
	StateError   State = "error"
	StateClear   State = "clear"
)

type Kind string

const (
	KindPermission Kind = "permission"
	KindQuestion   Kind = "question"
	KindAuth       Kind = "auth"
)

// Record represents a single OSC 7501 program status message. Only the fields
// a Mole reporter sends are modeled.
// ESC ] 7501 ; state=blocked:kind=permission:app=mole:title=bW9sZSBhbmFseXpl ESC \
type Record struct {
	State State
	Kind  Kind
	App   string
	Title string
}

var segment = regexp.MustCompile(`^[A-Za-z0-9_.+-]{1,32}$`)

func (record Record) Encode() (string, error) {
	switch record.State {
	case StateIdle, StateWorking, StateDone, StateBlocked, StateError, StateClear:
	default:
		return "", fmt.Errorf("invalid OSC 7501 state %q", record.State)
	}
	fields := []string{"state=" + string(record.State)}
	if record.State == StateBlocked && record.Kind != "" {
		switch record.Kind {
		case KindPermission, KindQuestion, KindAuth:
		default:
			return "", fmt.Errorf("invalid OSC 7501 kind %q", record.Kind)
		}
		fields = append(fields, "kind="+string(record.Kind))
	}
	if record.App != "" {
		if !segment.MatchString(record.App) {
			return "", fmt.Errorf("invalid OSC 7501 app %q", record.App)
		}
		fields = append(fields, "app="+record.App)
	}
	if record.Title != "" {
		if len(record.Title) > 192 || !utf8.ValidString(record.Title) || strings.ContainsFunc(record.Title, unicode.IsControl) {
			return "", fmt.Errorf("invalid OSC 7501 title")
		}
		fields = append(fields, "title="+base64.StdEncoding.EncodeToString([]byte(record.Title)))
	}
	return prefix + strings.Join(fields, ":") + terminator, nil
}
