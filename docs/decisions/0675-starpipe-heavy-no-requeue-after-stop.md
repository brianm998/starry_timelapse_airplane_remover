# 0675: starpipe heavy does not queue again after a stop or a gone caller

`run_job` re-queued whenever the started marker was missing and the code non-zero, so a SIGTERM'd or SIGKILLed `mason run`, or an
orphaned starpipe (ppid 1), kept queueing (task 669's stuck build). Now `_attempt` records a stop signal and whether the child died of
a signal; the loop returns in either case (a stop exits 128 + signal), and also when `os.getppid()` changed since start (message
"the caller has gone; not queueing <cmd> again", non-zero). A `mason run` that exits with a plain status and no marker is still
treated as masond dropping the request, up to `REQUEUE_MAX`.
