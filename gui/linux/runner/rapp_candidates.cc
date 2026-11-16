#include "rapp_candidates.h"
#include <algorithm>
#include <map>
#include <set>
#include <cstring>

namespace rapp {
namespace {
constexpr const char *service = "org.fcitx.Fcitx5";
constexpr const char *path = "/org/fcitx/Fcitx5/SumiCandidates";
constexpr const char *interface = "org.fcitx.Fcitx.SumiCandidates1";
std::weak_ptr<CandidateLease> active;
using Weak = std::weak_ptr<CandidateLease>;
struct Request { Weak lease; uint64_t epoch; };
void destroy_weak(gpointer p) { delete static_cast<Weak *>(p); }
}
CandidateLease::CandidateLease(Changed changed) : changed_(std::move(changed)) {}
std::shared_ptr<CandidateLease> CandidateLease::create(Changed changed) {
  auto lease = std::shared_ptr<CandidateLease>(new CandidateLease(std::move(changed)));
  lease->timer_ = g_timeout_add_full(G_PRIORITY_DEFAULT, 100,
    +[](gpointer p) -> gboolean {
      if (auto s = static_cast<Weak *>(p)->lock()) s->tick();
      return G_SOURCE_CONTINUE;
    }, new Weak(lease), destroy_weak);
  return lease;
}
CandidateLease::~CandidateLease() {
  changed_ = nullptr;
  release();
  if (timer_) g_source_remove(timer_);
}
void CandidateLease::clear() {
  paint_deadline_ = 0;
  snapshot_.rows.clear();
  snapshot_.cursor = -1;
  snapshot_.previous = snapshot_.next = false;
  if (changed_) changed_(snapshot_);
}
void CandidateLease::release() {
  eligible_ = false;
  accepted_ = connecting_ = false;
  ++epoch_;
  if (bus_) {
    // A private connection makes even a failed Release safe: owner disconnect
    // restores the normal candidate callback in Fcitx.
    const char *programs[] = {g_get_prgname(), nullptr};
    call("SetActive", g_variant_new("(s^asb)", snapshot_.token.c_str(), programs, FALSE));
    if (closed_) g_signal_handler_disconnect(bus_, closed_);
    closed_ = 0;
    if (signals_) g_dbus_connection_signal_unsubscribe(bus_, signals_);
    if (owner_signal_) g_dbus_connection_signal_unsubscribe(bus_, owner_signal_);
    signals_ = owner_signal_ = 0;
    g_dbus_connection_close(bus_, nullptr, nullptr, nullptr);
    g_clear_object(&bus_);
  }
  clear();
}
void CandidateLease::fail() {
  const bool wanted = eligible_;
  release();
  eligible_ = wanted;
  retry_at_ = g_get_monotonic_time() + 1500000;
}
void CandidateLease::update(bool eligible, bool can_retry) {
  can_retry_ = can_retry;
  if (!eligible) {
    if (eligible_ || accepted_ || connecting_) release();
    return;
  }
  eligible_ = true;
  if (auto old = active.lock(); old && old.get() != this) old->release();
  active = shared_from_this();
  tick();
}
void CandidateLease::tick() {
  if (paint_deadline_ && g_get_monotonic_time() > paint_deadline_) { fail(); return; }
  if (eligible_ && !accepted_ && !connecting_ && can_retry_ && g_get_monotonic_time() >= retry_at_) start();
}
void CandidateLease::start() {
  connecting_ = true;
  ++epoch_;
  g_autofree gchar *uuid = g_uuid_string_random();
  snapshot_ = CandidateSnapshot{};
  snapshot_.token = uuid;
  connect();
}
void CandidateLease::connect() {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (!address) { fail(); return; }
  g_dbus_connection_new_for_address(address,
    static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
    nullptr, nullptr, +[](GObject *, GAsyncResult *result, gpointer data) {
      std::unique_ptr<Request> r(static_cast<Request *>(data));
      g_autoptr(GError) error = nullptr;
      auto *bus = g_dbus_connection_new_for_address_finish(result, &error);
      auto s = r->lease.lock();
      if (!s || s->epoch_ != r->epoch || !s->eligible_) {
        if (bus) { g_dbus_connection_close(bus, nullptr, nullptr, nullptr); g_object_unref(bus); }
        return;
      }
      if (!bus) { s->fail(); return; }
      s->bus_ = bus;
      s->closed_ = g_signal_connect_data(bus, "closed", G_CALLBACK(+[](GDBusConnection *, gboolean, GError *, gpointer p) {
        if (auto s = static_cast<Weak *>(p)->lock()) s->fail();
      }), new Weak(s), +[](gpointer p, GClosure *) { destroy_weak(p); }, GConnectFlags(0));
      g_dbus_connection_set_exit_on_close(bus, FALSE);
      s->signals_ = g_dbus_connection_signal_subscribe(bus, service, interface, nullptr, path, nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE, +[](GDBusConnection *, const gchar *, const gchar *, const gchar *, const gchar *name, GVariant *value, gpointer p) {
          if (auto s = static_cast<Weak *>(p)->lock()) s->signal(name, value);
        }, new Weak(s), destroy_weak);
      s->owner_signal_ = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", service,
        G_DBUS_SIGNAL_FLAGS_NONE, +[](GDBusConnection *, const gchar *, const gchar *, const gchar *, const gchar *, GVariant *, gpointer p) {
          if (auto s = static_cast<Weak *>(p)->lock()) s->fail();
        }, new Weak(s), destroy_weak);
      const char *programs[] = {g_get_prgname(), nullptr};
      g_dbus_connection_call(bus, service, path, interface, "SetActive",
        g_variant_new("(s^asb)", s->snapshot_.token.c_str(), programs, TRUE), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, nullptr,
        +[](GObject *source, GAsyncResult *result, gpointer data) {
          std::unique_ptr<Request> r(static_cast<Request *>(data));
          g_autoptr(GError) error = nullptr;
          g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
          auto s = r->lease.lock();
          if (!s || s->epoch_ != r->epoch) return; // the private old connection was closed
          gboolean accepted = FALSE;
          if (reply) g_variant_get(reply, "(b)", &accepted);
          s->connecting_ = false;
          if (!accepted || !s->eligible_) { s->fail(); return; }
          s->accepted_ = true;
        }, new Request{Weak(s), s->epoch_});
    }, new Request{Weak(shared_from_this()), epoch_});
}
void CandidateLease::call(const char *name, GVariant *args) {
  if (!bus_) { g_variant_ref_sink(args); g_variant_unref(args); return; }
  g_dbus_connection_call(bus_, service, path, interface, name, args, nullptr,
    G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, nullptr,
    +[](GObject *source, GAsyncResult *result, gpointer data) {
      std::unique_ptr<Request> r(static_cast<Request *>(data));
      g_autoptr(GError) error = nullptr;
      g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
      if (auto s = r->lease.lock(); s && s->epoch_ == r->epoch && error) s->fail();
    }, new Request{weak_from_this(), epoch_});
}
void CandidateLease::signal(const char *name, GVariant *value) {
  if (!eligible_) return;
  if (std::string(name) == "Revoked" && g_variant_is_of_type(value, G_VARIANT_TYPE("(s)"))) {
    const char *token;
    g_variant_get(value, "(&s)", &token);
    if (snapshot_.token == token) fail();
    return;
  }
  if (std::string(name) != "Candidates" || !g_variant_is_of_type(value, G_VARIANT_TYPE("(sta(iss)ibb)"))) return;
  const char *token;
  guint64 serial;
  gint32 cursor;
  gboolean previous, next;
  g_autoptr(GVariant) rows = nullptr;
  g_variant_get(value, "(&st@a(iss)ibb)", &token, &serial, &rows, &cursor, &previous, &next);
  if (snapshot_.token != token || serial <= snapshot_.serial) return;
  if (g_variant_n_children(rows) > 512 || g_variant_get_size(value) > 256 * 1024) { fail(); return; }
  CandidateSnapshot snapshot;
  snapshot.token = token; snapshot.serial = serial; snapshot.cursor = cursor;
  snapshot.previous = previous; snapshot.next = next;
  std::set<int> indices;
  for (gsize i = 0; i < g_variant_n_children(rows); ++i) {
    gint32 index; const char *label, *text;
    g_variant_get_child(rows, i, "(i&s&s)", &index, &label, &text);
    if (index < 0 || !indices.insert(index).second || strlen(label) > 32768 || strlen(text) > 32768) { fail(); return; }
    snapshot.rows.push_back({index, label, text});
  }
  snapshot_ = std::move(snapshot);
  // Do not extend an unacknowledged paint deadline on every keystroke.
  if (snapshot_.rows.empty()) paint_deadline_ = 0;
  else if (!paint_deadline_) paint_deadline_ = g_get_monotonic_time() + 1000000;
  if (changed_) changed_(snapshot_);
}
void CandidateLease::rendered(const std::string &token, uint64_t serial) {
  if (token == snapshot_.token && serial == snapshot_.serial) paint_deadline_ = 0;
}
void CandidateLease::select(const std::string &token, uint64_t serial, int index) {
  if (!eligible_ || !accepted_ || token != snapshot_.token || serial != snapshot_.serial ||
      std::none_of(snapshot_.rows.begin(), snapshot_.rows.end(), [index](const auto &r) { return r.index == index; })) return;
  call("Select", g_variant_new("(sti)", token.c_str(), serial, index));
  clear();
}
void CandidateLease::page(const std::string &token, uint64_t serial, bool next) {
  if (!eligible_ || !accepted_ || token != snapshot_.token || serial != snapshot_.serial ||
      !(next ? snapshot_.next : snapshot_.previous)) return;
  call("Page", g_variant_new("(stb)", token.c_str(), serial, next));
  clear();
}
}
