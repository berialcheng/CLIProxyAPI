package registry

import (
	"strings"
	"sync"

	log "github.com/sirupsen/logrus"
)

// ModelOverride represents user-configured local overrides for a single model.
// Applied when model metadata leaves the registry, so registry-backed model
// lists and clients see the effective values while the registry retains the
// original catalog data.
//
// Override store lives independently from the catalog source: remote
// models.json refreshes replace modelsCatalogStore.data but never touch
// this store, so local overrides always win without disabling remote
// updates.
//
// Field semantics:
//   - int fields: 0 means "do not override"; any positive value overrides.
//     This avoids ambiguity for fields where 0 is never a meaningful value.
//   - string fields: nil means "do not override"; a non-nil pointer
//     overrides, allowing callers to explicitly clear a value with "".
type ModelOverride struct {
	ContextLength       int     `yaml:"context_length,omitempty" json:"context_length,omitempty"`
	MaxCompletionTokens int     `yaml:"max_completion_tokens,omitempty" json:"max_completion_tokens,omitempty"`
	DisplayName         *string `yaml:"display_name,omitempty" json:"display_name,omitempty"`
	Description         *string `yaml:"description,omitempty" json:"description,omitempty"`
}

var (
	overridesMu sync.RWMutex
	overrides   map[string]ModelOverride
)

// SetModelOverrides replaces the entire local override table.
// Passing nil or an empty map clears all overrides.
// Safe to call at any time, including from config hot-reload.
func SetModelOverrides(m map[string]ModelOverride) {
	normalized := make(map[string]ModelOverride, len(m))
	for id, o := range m {
		key := strings.TrimSpace(id)
		if key == "" {
			continue
		}
		copyOverride := o
		if o.DisplayName != nil {
			value := *o.DisplayName
			copyOverride.DisplayName = &value
		}
		if o.Description != nil {
			value := *o.Description
			copyOverride.Description = &value
		}
		normalized[key] = copyOverride
	}

	if len(normalized) == 0 {
		normalized = nil
	}

	// Model-list responses are cached by the global registry. Keep the lock
	// order consistent with registry reads (registry, then overrides) so a
	// hot reload cannot publish new overrides while leaving an old cached
	// /v1/models response visible.
	modelRegistry := GetGlobalRegistry()
	modelRegistry.mutex.Lock()
	overridesMu.Lock()
	hadOverrides := len(overrides) > 0
	overrides = normalized
	overridesMu.Unlock()
	modelRegistry.invalidateAvailableModelsCacheLocked()
	modelRegistry.mutex.Unlock()

	if len(normalized) == 0 {
		if hadOverrides {
			log.Infof("registry: local model overrides cleared")
		}
		return
	}

	log.Infof("registry: applied local model overrides for %d model(s)", len(normalized))
	for id, o := range normalized {
		fields := make([]string, 0, 4)
		if o.ContextLength > 0 {
			fields = append(fields, "context_length")
		}
		if o.MaxCompletionTokens > 0 {
			fields = append(fields, "max_completion_tokens")
		}
		if o.DisplayName != nil {
			fields = append(fields, "display_name")
		}
		if o.Description != nil {
			fields = append(fields, "description")
		}
		log.Debugf("registry: override %s -> %v", id, fields)
	}
}

// applyModelOverride mutates info in place to apply any matching override.
// No-op when the model has no override entry or when override fields are
// at their zero values. Called only on a private read-path copy, so mutating
// here is safe.
func applyModelOverride(modelID string, info *ModelInfo) {
	if info == nil {
		return
	}

	overridesMu.RLock()
	o, ok := overrides[modelID]
	overridesMu.RUnlock()
	if !ok {
		return
	}

	if o.ContextLength > 0 {
		info.ContextLength = o.ContextLength
		// The Codex client catalog uses MaxContextLength as the explicit
		// override signal for template-backed models. Set both fields so a
		// catalog-wide override follows the upstream max-context-length path.
		info.MaxContextLength = o.ContextLength
	}
	if o.MaxCompletionTokens > 0 {
		info.MaxCompletionTokens = o.MaxCompletionTokens
	}
	if o.DisplayName != nil {
		info.DisplayName = *o.DisplayName
	}
	if o.Description != nil {
		info.Description = *o.Description
	}
}
