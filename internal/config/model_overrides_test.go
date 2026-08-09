package config

import (
	"encoding/json"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestModelOverridesConfigDecoding(t *testing.T) {
	const yamlConfig = `model-overrides:
  gpt-5.6-luna:
    context_length: 272000
    max_completion_tokens: 64000
    display_name: "GPT-5.6 Luna (capped)"
    description: ""
`
	const jsonConfig = `{"model-overrides":{"gpt-5.6-luna":{"context_length":272000,"max_completion_tokens":64000,"display_name":"GPT-5.6 Luna (capped)","description":""}}}`

	for _, testCase := range []struct {
		name   string
		decode func(*Config) error
	}{
		{
			name: "YAML",
			decode: func(cfg *Config) error {
				return yaml.Unmarshal([]byte(yamlConfig), cfg)
			},
		},
		{
			name: "JSON",
			decode: func(cfg *Config) error {
				return json.Unmarshal([]byte(jsonConfig), cfg)
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			var cfg Config
			if errDecode := testCase.decode(&cfg); errDecode != nil {
				t.Fatalf("decode config: %v", errDecode)
			}

			override, ok := cfg.ModelOverrides["gpt-5.6-luna"]
			if !ok {
				t.Fatalf("model override missing: %#v", cfg.ModelOverrides)
			}
			if override.ContextLength != 272000 {
				t.Errorf("context_length = %d, want 272000", override.ContextLength)
			}
			if override.MaxCompletionTokens != 64000 {
				t.Errorf("max_completion_tokens = %d, want 64000", override.MaxCompletionTokens)
			}
			if override.DisplayName == nil || *override.DisplayName != "GPT-5.6 Luna (capped)" {
				t.Errorf("display_name = %#v, want configured value", override.DisplayName)
			}
			if override.Description == nil || *override.Description != "" {
				t.Errorf("description = %#v, want explicit empty string", override.Description)
			}
		})
	}
}
