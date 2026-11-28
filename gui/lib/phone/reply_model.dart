import '../ui/main_state.dart' show DeviceProbe;

/// Whether device [id] can answer a session without a view (its `apps` capabilities carry `reply`).
bool deviceCanReply(Map<String, DeviceProbe> probes, String id) => probes[id]?.apps?.capabilities?['reply'] == true;
