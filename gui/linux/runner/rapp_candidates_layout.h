#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace rapp {
struct CandidatePage {
  size_t start = 0, end = 0;
  std::vector<double> widths;
};
// Local positions are only for layout; selection retains the engine's real index.
inline CandidatePage candidate_page(const std::vector<double> &widths,
                                    double available, double gap, size_t selected) {
  CandidatePage page;
  if (widths.empty() || !std::isfinite(available) || available <= 0) return page;
  selected = std::min(selected, widths.size() - 1);
  double used = 0;
  for (size_t i = 0; i < widths.size(); ++i) {
    const double width = std::clamp(widths[i], 1.0, std::max(1.0, available));
    const double extra = page.widths.empty() ? 0 : std::max(0.0, gap);
    if (!page.widths.empty() && used + extra + width > available) {
      page.end = i;
      if (selected < i) return page;
      page = CandidatePage{};
      page.start = i;
      used = 0;
    }
    if (!page.widths.empty()) used += std::max(0.0, gap);
    page.widths.push_back(width);
    used += width;
  }
  page.end = widths.size();
  return page;
}
}
