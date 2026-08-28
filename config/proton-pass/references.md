# Proton Pass item convention

The setup wizard discovers these optional secrets automatically:

| Environment variable | Vault | Item title | Hidden field |
| --- | --- | --- | --- |
| `DEEPSEEK_API_KEY` | Development | `llm-deepseek` | `API Key` |
| `GEMINI_API_KEY` | Development | `llm-google` | `API Key` |
| `MOONSHOT_API_KEY` | Development | `llm-moonshotai` | `API Key` |

The legacy titles `llm-gemini` and `llm-moonshot` remain valid aliases.

Only the three field values are secret. The wizard reads secret-free vault/item
summaries, creates opaque references from the discovered IDs, and verifies each
field without displaying its value. If an item is recreated, rerun `bro auth`;
do not copy IDs or edit `pi.env` manually.
