package models

import (
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
)

func TestCodexClientModelsResponseAppliesAndClearsLocalContextOverride(t *testing.T) {
	const (
		clientID = "codex-local-model-override-test"
		modelID  = "gpt-5.6-luna"
		want     = 272000
	)

	registry.SetModelOverrides(nil)
	model := registry.LookupStaticModelInfo(modelID)
	if model == nil {
		t.Skipf("embedded catalog missing %s", modelID)
	}

	modelRegistry := registry.GetGlobalRegistry()
	modelRegistry.RegisterClient(clientID, "codex", []*registry.ModelInfo{model})
	t.Cleanup(func() {
		registry.SetModelOverrides(nil)
		modelRegistry.UnregisterClient(clientID)
	})

	contextWindow := func() int {
		response := BuildResponse(modelRegistry.GetAvailableModels("openai"), func(id string) []string {
			return modelRegistry.GetModelProviders(id)
		}, false)
		entries, ok := response["models"].([]map[string]any)
		if !ok {
			t.Fatalf("models type = %T, want []map[string]any", response["models"])
		}
		for _, entry := range entries {
			if stringModelValue(entry, "slug") == modelID {
				return intModelValue(entry, "context_window")
			}
		}
		t.Fatalf("Codex response missing %s", modelID)
		return 0
	}

	baseline := contextWindow()
	if baseline <= 0 || baseline == want {
		t.Fatalf("baseline context_window = %d, want a positive non-override value", baseline)
	}

	registry.SetModelOverrides(map[string]registry.ModelOverride{
		modelID: {ContextLength: want},
	})
	if got := contextWindow(); got != want {
		t.Fatalf("overridden context_window = %d, want %d", got, want)
	}

	registry.SetModelOverrides(nil)
	if got := contextWindow(); got != baseline {
		t.Fatalf("context_window after clear = %d, want baseline %d", got, baseline)
	}
}
