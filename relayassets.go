package relayassets

import "embed"

// Web contains the same responsive client shipped in Warren.app. Keeping the
// embed declaration at the repository root avoids a second, drifting copy of
// the PWA inside the deployable Relay Service.
//
//go:embed Web/dist/*
var Web embed.FS
