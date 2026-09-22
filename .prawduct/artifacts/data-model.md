# Data model

Not relevant: aidc has no database. Its state is a few small files: config YAML, each session's
audit dir, and aidc-mcp's state (watch and send-queue JSON, one per session). Each file's format is
documented where it is written. Revisit if aidc ever grows a real data store.
