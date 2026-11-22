# 0893: order the Stop's cancel before the next Start

Tagging a cancel with a run token was considered. Reading the current generation from the builder actor is itself async, so a token captured at Stop time would race the same way. Instead `stopProcessing` keeps its cancel Task and `beginProcessing` awaits it before building, so the cancel is always older than the next build's `generationOnEntry`. A build still dropped (a cancel that really arrives mid-build) calls `cancelledClosure`, never `closure` or `errorClosure`; each caller ignores a drop from a stale run.
