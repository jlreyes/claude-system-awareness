// displaycount — prints the number of active displays via CoreGraphics.
// Used by system-context-nudge.sh to detect monitor add/remove (changed
// workstation). ~10ms to run vs ~400ms for `system_profiler`.
// Rebuild:  swiftc -O displaycount.swift -o displaycount
import CoreGraphics

var count: UInt32 = 0
let err = CGGetActiveDisplayList(0, nil, &count)
print(err == .success ? count : 0)
