package relayassets

import "embed"

// Web contains the same responsive client shipped in Burrow.app. Keeping the
// embed declaration at the repository root avoids a second, drifting copy of
// the PWA inside the deployable Relay Service.
//
//go:embed Packages/WebRelay/Sources/WebRelay/Resources/*
var Web embed.FS
