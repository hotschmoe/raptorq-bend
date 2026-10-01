#!/usr/bin/env python3
"""usage: rss.py cmd args...  -> runs it, prints peak RSS (MB) and wall ms of the child"""
import resource, subprocess, sys, time
t=time.time(); subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL); w=time.time()-t
print(f"peak_rss_mb={resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss/1024:.0f} wall_ms={w*1000:.0f}")
