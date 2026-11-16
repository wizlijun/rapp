// Headless CandidateLease checks. Run only on the script-created private bus.
#include "candidates_mock.h"
#include <csignal>
#include <limits>
#include <unistd.h>

int main() {
  try {
    require(g_strcmp0(g_getenv("RAPP_CANDIDATES_ISOLATED_TEST"), "1") == 0, "run only through the private-bus script");
    g_set_prgname("com.rapp.rapp");
    Mock mock;
    {
      auto lease = rapp::CandidateLease::create([](const auto &) {});
      lease->update(true, false);
      spin(120);
      require(mock.registrations == 0, "registered during existing composition");
      lease->update(true, true);
      wait([&] { return lease->accepted() && !lease->snapshot().rows.empty(); }, "registration/early frame missing");
      const auto frame = lease->snapshot();
      require(frame.rows[0].index == 7 && frame.rows[1].index == 12, "candidate indices renumbered");
      mock.frame(frame.serial + 20, "old-token");
      mock.revoke("old-token");
      spin(30);
      require(lease->accepted() && lease->snapshot().serial == frame.serial, "stale signal changed lease");
      lease->select("old-token", frame.serial, 7);
      lease->select(frame.token, frame.serial - 1, 7);
      lease->select(frame.token, frame.serial, 0);
      lease->page(frame.token, frame.serial, false);
      spin(30);
      require(mock.selections == 0 && mock.pages == 0, "invalid action reached Fcitx");
      lease->select(frame.token, frame.serial, 7);
      lease->select(frame.token, frame.serial, 7);
      wait([&] { return mock.selections == 1 && !lease->snapshot().rows.empty(); }, "valid selection/new frame lost");
      const auto next = lease->snapshot();
      lease->page(next.token, next.serial, true);
      lease->page(next.token, next.serial, true);
      wait([&] { return mock.pages == 1 && !lease->snapshot().rows.empty(); }, "valid page/new frame lost");
      lease->update(false, true);
      require(!lease->accepted() && lease->snapshot().rows.empty(), "focus loss did not clear candidates");
      check("composition gating, early frame, real indices, stale signals/actions, single-use selection/page and focus release");
    }
    spin(30);
    {
      mock.registration = Mock::Reply::Hold;
      auto lease = rapp::CandidateLease::create([](const auto &) {});
      lease->update(true, true);
      wait([&] { return !mock.held.empty(); }, "registration not pending");
      const auto old_token = mock.token;
      lease->release();
      mock.finishHeld(true);
      spin(30);
      require(!lease->accepted() && lease->snapshot().rows.empty(), "late registration restored released lease");
      mock.registration = Mock::Reply::Accept;
      lease->update(true, true);
      wait([&] { return lease->accepted(); }, "new registration missing");
      require(mock.token != old_token, "token reused after release");
      check("release during registration discards late success and next focus uses a fresh token");
    }
    spin(30);
    {
      auto lease = ready(mock);
      mock.revoke(mock.token);
      wait([&] { return !lease->accepted(); }, "revoked lease retained");
      require(lease->snapshot().rows.empty(), "revoked candidates retained");
      check("matching revocation clears accepted state and panel");
    }
    spin(30);
    {
      auto lease = ready(mock);
      spin(1100);
      require(lease->accepted(), "acknowledged paint expired");
      mock.frame(++mock.serial);
      wait([&] { return lease->snapshot().serial == mock.serial; }, "new frame missing");
      lease->rendered("stale-token", mock.serial);
      wait([&] { return !lease->accepted(); }, "missing paint acknowledgement did not release lease", 1400);
      check("paint acknowledgement keeps lease; stale acknowledgement cannot suppress watchdog");
    }
    spin(30);
    {
      auto lease = ready(mock);
      mock.name(false);
      wait([&] { return !lease->accepted(); }, "service disappearance retained lease");
      mock.name(true);
      check("service owner disappearance releases lease");
    }
    spin(30);
    {
      auto first = ready(mock);
      const auto first_frame = first->snapshot();
      auto second = ready(mock);
      require(!first->accepted() && first->snapshot().rows.empty(), "two editors retain ownership");
      require(second->snapshot().token != first_frame.token, "editors share token");
      first->update(false, true);
      mock.revoke(first_frame.token);
      spin(30);
      require(second->accepted(), "old editor release/revocation affected current editor");
      check("process coordinator releases the previous editor and isolates its stale events");
    }
    spin(30);
    for (const auto failure : {Mock::Reply::Reject, Mock::Reply::Error}) {
      const auto before = mock.registrations;
      mock.registration = failure;
      auto lease = rapp::CandidateLease::create([](const auto &) {});
      lease->update(true, true);
      wait([&] { return mock.registrations > before; }, "rejection request missing");
      spin(30);
      require(!lease->accepted() && lease->snapshot().rows.empty(), "registration failure retained candidates");
    }
    check("registration rejection and missing method preserve fallback");
    spin(30);
    {
      auto lease = ready(mock);
      mock.serial = std::numeric_limits<guint64>::max();
      mock.frame(mock.serial);
      wait([&] { return lease->snapshot().serial == mock.serial; }, "full uint64 serial was rejected");
      const auto frame = lease->snapshot();
      const auto before = mock.selections;
      mock.action = Mock::Reply::Hold;
      lease->select(frame.token, frame.serial, frame.rows[0].index);
      lease->select(frame.token, frame.serial, frame.rows[0].index);
      wait([&] { return !mock.held.empty(); }, "full uint64 selection not delivered");
      require(mock.selections == before + 1 && mock.last_selection_serial == frame.serial,
              "full uint64 serial narrowed or selection repeated");
      lease->release();
      mock.finishHeld(true);
      check("maximum uint64 serial reaches Fcitx unchanged and cannot be selected twice");
    }
    spin(30);
    for (bool page : {false, true}) {
      auto lease = ready(mock);
      mock.action = Mock::Reply::Error;
      const auto frame = lease->snapshot();
      if (page) lease->page(frame.token, frame.serial, true);
      else lease->select(frame.token, frame.serial, frame.rows[0].index);
      wait([&] { return !lease->accepted(); }, "action failure retained invisible accepted lease", 500);
    }
    check("selection and paging errors release ownership instead of hiding candidates indefinitely");
    spin(30);
    {
      auto lease = ready(mock);
      mock.action = Mock::Reply::Hold;
      const auto frame = lease->snapshot();
      lease->select(frame.token, frame.serial, frame.rows[0].index);
      wait([&] { return !mock.held.empty(); }, "action not pending");
      wait([&] { return !lease->accepted(); }, "action timeout retained ownership", 1300);
      mock.finishHeld(false);
      check("action timeout releases ownership without replaying a possibly committed selection");
    }
    spin(30);
    {
      auto lease = ready(mock);
      mock.action = Mock::Reply::Hold;
      const auto frame = lease->snapshot();
      lease->page(frame.token, frame.serial, true);
      wait([&] { return !mock.held.empty(); }, "old action not pending");
      lease->release();
      mock.action = Mock::Reply::Accept;
      lease->update(true, true);
      wait([&] { return lease->accepted(); }, "successor lease missing");
      mock.finishHeld(false);
      spin(50);
      require(lease->accepted(), "old action failure revoked successor lease");
      check("late action error cannot revoke a successor epoch");
    }
    spin(30);
    {
      auto lease = ready(mock);
      // This is the fresh bus created by run-candidates-bridge.sh, never the
      // desktop bus. End it to exercise the transport's actual closed signal.
      require(g_strcmp0(g_dbus_connection_get_unique_name(mock.bus), ":1.0") == 0,
              "refusing to stop a bus that was not created for this test");
      g_autoptr(GVariant) reply = g_dbus_connection_call_sync(mock.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetConnectionUnixProcessID", g_variant_new("(s)", "org.freedesktop.DBus"),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
      require(reply != nullptr, "private daemon PID unavailable");
      guint32 pid = 0;
      g_variant_get(reply, "(u)", &pid);
      require(pid > 1 && pid != static_cast<guint32>(getpid()), "invalid private daemon PID");
      require(kill(static_cast<pid_t>(pid), SIGTERM) == 0, "cannot stop private test daemon");
      wait([&] { return !lease->accepted(); }, "closed bus retained accepted lease", 500);
      require(lease->snapshot().rows.empty(), "closed bus retained candidates");
      check("actual private bus disconnect clears ownership without terminating the application");
    }
    spin(30);
    std::cout << "All private candidate bridge checks passed.\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
