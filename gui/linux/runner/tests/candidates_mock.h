// Shared private-bus fixture; the real Fcitx integration tests cover commits.
#pragma once
#include "rapp_candidates.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace {
constexpr const char *service = "org.fcitx.Fcitx5";
constexpr const char *path = "/org/fcitx/Fcitx5/SumiCandidates";
constexpr const char *interface = "org.fcitx.Fcitx.SumiCandidates1";
void require(bool value, const char *message) {
  if (!value) throw std::runtime_error(message);
}
void spin(int ms) {
  const auto until = g_get_monotonic_time() + ms * 1000;
  do {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  } while (g_get_monotonic_time() < until);
}
template<class Predicate> void wait(Predicate predicate, const char *message, int ms = 2000) {
  const auto until = g_get_monotonic_time() + ms * 1000;
  while (!predicate() && g_get_monotonic_time() < until) spin(2);
  require(predicate(), message);
}
struct Mock {
  enum class Reply { Accept, Reject, Error, Hold };
  GDBusConnection *bus = nullptr;
  GDBusNodeInfo *info = nullptr;
  guint object = 0;
  Reply registration = Reply::Accept, action = Reply::Accept;
  unsigned registrations = 0, selections = 0, pages = 0, releases = 0;
  gint32 last_selection = -1;
  guint64 last_selection_serial = 0;
  std::string last_selection_token;
  struct Row { gint32 index; std::string label, text; };
  std::vector<Row> rows{{7, "1", "你好"}, {12, "2", "拟好"}};
  gint32 cursor = 7;
  bool previous = false, next = true;
  std::string owner, token;
  guint64 serial = 0;
  std::vector<GDBusMethodInvocation *> held;
  Mock() {
    GError *error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    require(bus != nullptr, error ? error->message : "mock bus unavailable");
    g_dbus_connection_set_exit_on_close(bus, FALSE);
    info = g_dbus_node_info_new_for_xml(R"XML(
      <node><interface name='org.fcitx.Fcitx.SumiCandidates1'>
      <method name='SetActive'><arg type='s' direction='in'/><arg type='as' direction='in'/><arg type='b' direction='in'/><arg type='b' direction='out'/></method>
      <method name='Select'><arg type='s' direction='in'/><arg type='t' direction='in'/><arg type='i' direction='in'/></method>
      <method name='Page'><arg type='s' direction='in'/><arg type='t' direction='in'/><arg type='b' direction='in'/></method>
      <signal name='Candidates'><arg type='s'/><arg type='t'/><arg type='a(iss)'/><arg type='i'/><arg type='b'/><arg type='b'/></signal>
      <signal name='Revoked'><arg type='s'/></signal>
      </interface></node>)XML", &error);
    require(info != nullptr, "invalid test introspection");
    GDBusInterfaceVTable vtable{};
    vtable.method_call = +[](GDBusConnection *, const gchar *sender, const gchar *, const gchar *,
                            const gchar *method, GVariant *args, GDBusMethodInvocation *call, gpointer data) {
      static_cast<Mock *>(data)->request(sender, method, args, call);
    };
    object = g_dbus_connection_register_object(bus, path, info->interfaces[0], &vtable, this, nullptr, &error);
    require(object != 0, "cannot register test object");
    name(true);
  }
  ~Mock() {
    finishHeld(false);
    g_dbus_connection_unregister_object(bus, object);
    g_dbus_node_info_unref(info);
    g_object_unref(bus);
  }
  void name(bool acquire) {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", acquire ? "RequestName" : "ReleaseName",
      acquire ? g_variant_new("(su)", service, 0u) : g_variant_new("(s)", service),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    require(reply != nullptr, "cannot change mock service owner");
  }
  void request(const char *sender, const char *method, GVariant *args, GDBusMethodInvocation *call) {
    if (std::string(method) == "SetActive") {
      const char *requested;
      g_autoptr(GVariant) programs = nullptr;
      gboolean active;
      g_variant_get(args, "(&s@asb)", &requested, &programs, &active);
      if (!active) { ++releases; g_dbus_method_invocation_return_value(call, g_variant_new("(b)", TRUE)); return; }
      ++registrations;
      owner = sender; token = requested; serial = 0;
      if (registration == Reply::Accept) {
        frame(++serial); // Fcitx may emit the first frame before its method reply.
        g_dbus_method_invocation_return_value(call, g_variant_new("(b)", TRUE));
      } else if (registration == Reply::Reject) {
        g_dbus_method_invocation_return_value(call, g_variant_new("(b)", FALSE));
      } else if (registration == Reply::Error) {
        g_dbus_method_invocation_return_dbus_error(call, "org.freedesktop.DBus.Error.UnknownMethod", "fixture unavailable");
      } else held.push_back(G_DBUS_METHOD_INVOCATION(g_object_ref(call)));
      return;
    }
    if (std::string(method) == "Select") {
      ++selections;
      const char *requested;
      g_variant_get(args, "(&sti)", &requested, &last_selection_serial, &last_selection);
      last_selection_token = requested;
    }
    if (std::string(method) == "Page") ++pages;
    if (action == Reply::Error) {
      g_dbus_method_invocation_return_dbus_error(call, "org.freedesktop.DBus.Error.Failed", "fixture action failed");
    } else if (action == Reply::Hold) {
      held.push_back(G_DBUS_METHOD_INVOCATION(g_object_ref(call)));
    } else {
      frame(serial += 2);
      g_dbus_method_invocation_return_value(call, nullptr);
    }
  }
  void frame(guint64 number, const std::string &override_token = "") {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a(iss)"));
    for (const auto &row : rows)
      g_variant_builder_add(&builder, "(iss)", row.index, row.label.c_str(), row.text.c_str());
    g_dbus_connection_emit_signal(bus, owner.c_str(), path, interface, "Candidates",
      g_variant_new("(st@a(iss)ibb)", override_token.empty() ? token.c_str() : override_token.c_str(), number,
        g_variant_builder_end(&builder), cursor, previous, next), nullptr);
  }
  void revoke(const std::string &requested) {
    g_dbus_connection_emit_signal(bus, owner.c_str(), path, interface, "Revoked", g_variant_new("(s)", requested.c_str()), nullptr);
  }
  void finishHeld(bool success) {
    for (auto *call : std::exchange(held, {})) {
      if (!success) g_dbus_method_invocation_return_dbus_error(call, "org.freedesktop.DBus.Error.Failed", "late fixture failure");
      else if (std::string(g_dbus_method_invocation_get_method_name(call)) == "SetActive")
        g_dbus_method_invocation_return_value(call, g_variant_new("(b)", TRUE));
      else g_dbus_method_invocation_return_value(call, nullptr);
      g_object_unref(call);
    }
  }
};
[[maybe_unused]] std::shared_ptr<rapp::CandidateLease> ready(Mock &mock) {
  mock.registration = Mock::Reply::Accept;
  mock.action = Mock::Reply::Accept;
  auto lease = rapp::CandidateLease::create([](const auto &) {});
  lease->update(true, true);
  wait([&] { return lease->accepted() && !lease->snapshot().rows.empty(); }, "lease not ready");
  lease->rendered(lease->snapshot().token, lease->snapshot().serial);
  return lease;
}
void check(const char *label) { std::cout << "PASS: " << label << std::endl; }
}
