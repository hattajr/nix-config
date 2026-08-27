# Proton Pass ID map

Record only non-secret metadata here after the first authenticated setup.

| Environment variable | Vault | Item | Share ID | Item ID | Field |
| --- | --- | --- | --- | --- | --- |
| `DEEPSEEK_API_KEY` | Development | llm-deepseek | TODO | TODO | `API_KEY` |
| `GEMINI_API_KEY` | Development | llm-google | TODO | TODO | `API_KEY` |
| `MOONSHOT_API_KEY` | Development | llm-moonshot | TODO | TODO | `API_KEY` |

Update both this map and `pi.env.example` if an item is recreated. IDs are
opaque account metadata, not secret values; never put field values here.
