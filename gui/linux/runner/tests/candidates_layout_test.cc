#include "../rapp_candidates_layout.h"
#include <cassert>
#include <limits>

int main() {
  const std::vector<double> widths{30, 40, 70, 10};
  const auto first = rapp::candidate_page(widths, 80, 5, 0);
  assert(first.start == 0 && first.end == 2);
  const auto second = rapp::candidate_page(widths, 80, 5, 2);
  assert(second.start == 2 && second.end == 3);
  const auto third = rapp::candidate_page(widths, 80, 5, 3);
  assert(third.start == 3 && third.end == 4);
  assert(rapp::candidate_page(widths, 80, 5, second.start - 1).start == 0);
  // A long Unicode candidate is ellipsized by Pango; its logical index is kept.
  const auto long_word = rapp::candidate_page({500, 20}, 60, 5, 0);
  assert(long_word.start == 0 && long_word.end == 1 && long_word.widths[0] == 60);
  assert(rapp::candidate_page({500, 20}, 60, 5, 1).start == 1);
  assert(rapp::candidate_page({}, 80, 5, 0).widths.empty());
  assert(rapp::candidate_page(widths, 0, 5, 0).widths.empty());
  assert(rapp::candidate_page(widths, std::numeric_limits<double>::infinity(), 5, 0).widths.empty());
  // At several font/viewport scales, each candidate occurs exactly once across
  // pages and every nonempty page fits the allotted single row.
  for (double scale : {1., 1.2222, 1.5, 2.}) {
    std::vector<double> measured;
    for (double width : widths) measured.push_back(width * scale);
    for (double available : {20., 80., 200.}) {
      size_t next = 0;
      while (next < measured.size()) {
        const auto page = rapp::candidate_page(measured, available, 5 * scale, next);
        assert(page.start == next && page.end > next);
        double used = 0;
        for (double width : page.widths) used += width;
        used += (page.widths.size() - 1) * 5 * scale;
        assert(used <= available + .001);
        next = page.end;
      }
    }
  }
}
