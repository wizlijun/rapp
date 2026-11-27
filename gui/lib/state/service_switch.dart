// Turning the center service (rapp-center) on or off, here or on another device, and finding which device hosts it.

abstract interface class ServiceSwitchApi {
  /// Asks the state service on device [to] (this device when null) to turn [on] or off; without [on], for its status.
  /// Answers the device's reply (`on`, `running`, `port`, `error`, …); a failure is thrown, its text the reason.
  Future<Map<String, Object?>> stateService({String? to, bool? on});

  /// The 9-digit id of the device whose state service this network uses (this device's own id when it is here);
  /// null when there is none.
  Future<String?> stateHost();
}
