# Retry discipline

When a provider returns a transient capacity error, retry once with the same
bounded context bundle before selecting a documented fallback.
