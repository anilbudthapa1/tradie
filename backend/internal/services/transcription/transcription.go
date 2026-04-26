// Package transcription provides a swappable audio-to-text interface for
// voice job notes (M126). The default StubTranscriber returns a fixed
// "not configured" response — wire a real provider (Anthropic Claude audio,
// AssemblyAI, Deepgram, etc.) in production by setting ANTHROPIC_API_KEY
// and replacing it via NewFromConfig.
package transcription

import (
	"context"
	"errors"
)

// Transcriber turns an audio file URL into a text transcript.
type Transcriber interface {
	Transcribe(ctx context.Context, fileURL string) (string, error)
}

// ErrNotConfigured is returned by stub providers when no real backend is wired.
var ErrNotConfigured = errors.New("transcription provider not configured")

// StubTranscriber is the default implementation. It does NOT call any
// external API — it always returns a fixed string. needs-key:
// ANTHROPIC_API_KEY (for Claude audio) or ASSEMBLYAI_API_KEY.
type StubTranscriber struct{}

func (StubTranscriber) Transcribe(_ context.Context, _ string) (string, error) {
	return "Transcription not configured", nil
}

// NewFromConfig returns a Transcriber based on available API keys. For now
// the stub is always returned; this seam exists so callers don't need to
// change when a real provider is plugged in.
//
// To swap implementations: detect the relevant env var (e.g.
// ANTHROPIC_API_KEY) and return a real transcriber. The voice_notes handler
// already invokes this asynchronously and persists the result to
// voice_notes.transcript / transcription_status.
func NewFromConfig(anthropicAPIKey string) Transcriber {
	// Real provider wiring goes here once available.
	_ = anthropicAPIKey
	return StubTranscriber{}
}
