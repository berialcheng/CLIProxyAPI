package registry

import (
	"sync"
	"testing"
)

// resetOverridesForTest ensures a clean override store between tests.
// Not safe for concurrent tests; tests below run sequentially.
func resetOverridesForTest() {
	SetModelOverrides(nil)
}

func TestApplyModelOverride_ContextLength(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	// gpt-5.6-luna is present in the embedded catalog and can be narrowed by
	// local configuration without mutating the catalog source.
	const id = "gpt-5.6-luna"
	before := LookupStaticModelInfo(id)
	if before == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", id)
	}
	if before.ContextLength <= 0 {
		t.Fatalf("baseline context_length = %d, want a positive catalog value", before.ContextLength)
	}

	SetModelOverrides(map[string]ModelOverride{
		id: {ContextLength: 272000},
	})

	after := LookupStaticModelInfo(id)
	if after == nil {
		t.Fatalf("LookupStaticModelInfo(%q) returned nil after override set", id)
	}
	if got := after.ContextLength; got != 272000 {
		t.Fatalf("overridden context_length = %d, want 272000", got)
	}
	if got := after.MaxContextLength; got != 272000 {
		t.Fatalf("overridden max_context_length = %d, want 272000", got)
	}
}

func TestGetAvailableModelsIncludesLocalContextOverride(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const (
		id   = "gpt-5.6-luna"
		want = 272000
	)
	SetModelOverrides(map[string]ModelOverride{
		id: {ContextLength: want},
	})

	modelRegistry := newTestModelRegistry()
	modelRegistry.RegisterClient("local-model-override-test", "codex", []*ModelInfo{{
		ID:            id,
		ContextLength: 372000,
	}})

	models := modelRegistry.GetAvailableModels("openai")
	if len(models) != 1 {
		t.Fatalf("models length = %d, want 1", len(models))
	}
	if got := models[0]["context_length"]; got != want {
		t.Fatalf("context_length = %#v, want %d", got, want)
	}
	if got := models[0]["max_context_length"]; got != want {
		t.Fatalf("max_context_length = %#v, want %d", got, want)
	}
}

func TestStaticDefinitionsByChannelIncludesLocalContextOverride(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const (
		id   = "gpt-5.6-luna"
		want = 272000
	)
	SetModelOverrides(map[string]ModelOverride{
		id: {ContextLength: want},
	})

	for _, model := range GetStaticModelDefinitionsByChannel("codex") {
		if model == nil || model.ID != id {
			continue
		}
		if model.ContextLength != want {
			t.Fatalf("context_length = %d, want %d", model.ContextLength, want)
		}
		if model.MaxContextLength != want {
			t.Fatalf("max_context_length = %d, want %d", model.MaxContextLength, want)
		}
		return
	}

	t.Fatalf("GetStaticModelDefinitionsByChannel(codex) missing %s", id)
}

func TestApplyModelOverride_OtherModelUnaffected(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const overridden = "gpt-5.6-luna"
	const untouched = "gpt-5.4"
	untouchedBefore := LookupStaticModelInfo(untouched)
	if untouchedBefore == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", untouched)
	}
	wantContextLength := untouchedBefore.ContextLength

	SetModelOverrides(map[string]ModelOverride{
		overridden: {ContextLength: 272000},
	})

	got := LookupStaticModelInfo(untouched)
	if got == nil {
		t.Fatalf("LookupStaticModelInfo(%q) returned nil", untouched)
	}
	if got.ContextLength != wantContextLength {
		t.Fatalf("untouched model context_length = %d, want %d (override leaked across model IDs)",
			got.ContextLength, wantContextLength)
	}
}

func TestSetModelOverrides_ClearAndRestore(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const id = "gpt-5.6-luna"
	baseline := LookupStaticModelInfo(id)
	if baseline == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", id)
	}
	baselineContextLength := baseline.ContextLength

	// Apply an override.
	SetModelOverrides(map[string]ModelOverride{
		id: {ContextLength: 100000},
	})
	if got := LookupStaticModelInfo(id).ContextLength; got != 100000 {
		t.Fatalf("override not applied: got %d, want 100000", got)
	}

	// Clear via nil.
	SetModelOverrides(nil)
	if got := LookupStaticModelInfo(id).ContextLength; got != baselineContextLength {
		t.Fatalf("after clear, context_length = %d, want baseline %d", got, baselineContextLength)
	}

	// Clear via empty map should behave the same as nil.
	SetModelOverrides(map[string]ModelOverride{id: {ContextLength: 100000}})
	if got := LookupStaticModelInfo(id).ContextLength; got != 100000 {
		t.Fatalf("override not applied before empty-clear: got %d, want 100000", got)
	}
	SetModelOverrides(map[string]ModelOverride{})
	if got := LookupStaticModelInfo(id).ContextLength; got != baselineContextLength {
		t.Fatalf("after empty map clear, context_length = %d, want baseline %d", got, baselineContextLength)
	}
}

func TestApplyModelOverride_ZeroFieldIsNoOp(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const id = "gpt-5.6-luna"
	baseline := LookupStaticModelInfo(id)
	if baseline == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", id)
	}
	wantContextLength := baseline.ContextLength
	wantDisplayName := baseline.DisplayName

	// Override entry exists for the ID, but every override field is at its
	// zero value. The model should look identical to the baseline.
	SetModelOverrides(map[string]ModelOverride{
		id: {
			ContextLength:       0,
			MaxCompletionTokens: 0,
			DisplayName:         nil,
			Description:         nil,
		},
	})

	got := LookupStaticModelInfo(id)
	if got == nil {
		t.Fatalf("LookupStaticModelInfo(%q) returned nil", id)
	}
	if got.ContextLength != wantContextLength {
		t.Fatalf("zero-value override changed context_length: got %d, want %d",
			got.ContextLength, wantContextLength)
	}
	if got.DisplayName != wantDisplayName {
		t.Fatalf("zero-value override changed display_name: got %q, want %q",
			got.DisplayName, wantDisplayName)
	}
}

func TestApplyModelOverride_StringPointerOverride(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const id = "gpt-5.6-luna"
	baseline := LookupStaticModelInfo(id)
	if baseline == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", id)
	}

	const wantName = "GPT-5.6 Luna (capped)"
	newName := wantName
	SetModelOverrides(map[string]ModelOverride{
		id: {DisplayName: &newName},
	})

	got := LookupStaticModelInfo(id)
	if got == nil {
		t.Fatalf("LookupStaticModelInfo(%q) returned nil after override", id)
	}
	if got.DisplayName != wantName {
		t.Fatalf("display_name override not applied: got %q, want %q",
			got.DisplayName, wantName)
	}
	// Context_length should be unchanged because we did not touch it.
	if got.ContextLength != baseline.ContextLength {
		t.Fatalf("display_name override leaked into context_length: got %d, want %d",
			got.ContextLength, baseline.ContextLength)
	}
}

func TestSetModelOverridesDefensivelyCopiesStringPointers(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const id = "gpt-5.6-luna"
	name := "Configured name"
	description := "Configured description"
	SetModelOverrides(map[string]ModelOverride{
		id: {
			DisplayName: &name,
			Description: &description,
		},
	})

	name = "mutated outside registry"
	description = "mutated outside registry"
	got := LookupStaticModelInfo(id)
	if got == nil {
		t.Skipf("embedded catalog missing %s", id)
	}
	if got.DisplayName != "Configured name" {
		t.Fatalf("display_name = %q, want defensive copy", got.DisplayName)
	}
	if got.Description != "Configured description" {
		t.Fatalf("description = %q, want defensive copy", got.Description)
	}
}

func TestSetModelOverrides_ConcurrentSafe(t *testing.T) {
	t.Cleanup(resetOverridesForTest)

	const id = "gpt-5.6-luna"
	if LookupStaticModelInfo(id) == nil {
		t.Skipf("embed catalog missing %s; cannot run this test", id)
	}

	const workers = 8
	const iterations = 200
	var wg sync.WaitGroup
	wg.Add(workers)

	// Half the workers flip the override on; the other half keep reading.
	// The test only asserts no race / panic / deadlock; the observed
	// values are inherently nondeterministic and are not checked.
	for i := 0; i < workers; i++ {
		writer := i < workers/2
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				if writer {
					SetModelOverrides(map[string]ModelOverride{
						id: {ContextLength: 100000 + j%10},
					})
				} else {
					_ = LookupStaticModelInfo(id)
				}
			}
		}()
	}

	wg.Wait()
}
