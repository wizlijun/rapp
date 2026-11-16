#pragma once
#include <gtk/gtk.h>
#include <flutter_linux/flutter_linux.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// Presentation only. The toolkit's IM context still owns preedit and commits.
namespace rapp {
struct Candidate {
  int index;
  std::string label, text;
};
struct CandidateSnapshot {
  std::string token;
  uint64_t serial = 0;
  std::vector<Candidate> rows;
  int cursor = -1;
  bool previous = false, next = false;
};
class CandidateLease : public std::enable_shared_from_this<CandidateLease> {
public:
  using Changed = std::function<void(const CandidateSnapshot &)>;
  static std::shared_ptr<CandidateLease> create(Changed changed);
  ~CandidateLease();
  // can_retry is false while composing: never replace an existing system popup.
  void update(bool eligible, bool can_retry);
  void release();
  void rendered(const std::string &token, uint64_t serial);
  void select(const std::string &token, uint64_t serial, int index);
  void page(const std::string &token, uint64_t serial, bool next);
  const CandidateSnapshot &snapshot() const { return snapshot_; }
  bool accepted() const { return accepted_; }
private:
  explicit CandidateLease(Changed changed);
  void start();
  void connect();
  void tick();
  void clear();
  void signal(const char *name, GVariant *value);
  void call(const char *name, GVariant *args);
  void fail();
  Changed changed_;
  GDBusConnection *bus_ = nullptr;
  gulong closed_ = 0;
  guint signals_ = 0, owner_signal_ = 0, timer_ = 0;
  bool eligible_ = false, can_retry_ = true, connecting_ = false, accepted_ = false;
  uint64_t epoch_ = 0;
  gint64 retry_at_ = 0, paint_deadline_ = 0;
  CandidateSnapshot snapshot_;
};
// Installs a separate MethodChannel for Flutter editors; no text is sent through it.
void set_flutter_candidates_secure(GtkWidget *view, bool secure);
void register_flutter_candidates(FlBinaryMessenger *messenger, GtkWidget *view, GtkWindow *window);
}
