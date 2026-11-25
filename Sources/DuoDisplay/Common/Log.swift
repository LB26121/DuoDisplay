import os

/// Persistent diagnostics (stats once per second while streaming, mode changes).
/// Read with: log show --last 10m --predicate 'subsystem == "local.duodisplay"' --style compact
let ddLog = Logger(subsystem: "local.duodisplay", category: "stream")
