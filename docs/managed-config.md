# Managed Config Contract

Verbatim reads an optional JSON document from a managed URL and caches the last valid response locally in Application Support.

Fields:

- `vocabulary.promptHints`: prompt text forwarded to Groq.
- `vocabulary.terms`: post-transcription replacements applied locally.
- `defaultLanguage`: language code sent to Groq.
- `providerPolicy`: one of `groq_primary_local_fallback`, `local_only`, `groq_only`.
- `features.cloudTranscriptionAllowed`: forces local-only mode when false.
- `features.pasteInPlaceAllowed`: forces clipboard mode when false.
- `features.inAppUpdatesEnabled`: hides or disables Sparkle-driven update checks when false.

Precedence:

1. `com.apple.configuration.managed` values override everything.
2. Managed config JSON overrides local user defaults for shared policy.
3. Local user preferences remain in effect for personal UX settings.

The external iPhone/Netlify companion is expected to consume the same JSON shape.
