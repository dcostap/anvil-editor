// Histogram matching core adapted from hdiff by Ray Gardner (0BSD).
// See vendor/UPSTREAM.md and vendor/hdiff/LICENSE.
// Shortest-edit-script fallback uses DTL by Tatsuhiko Kubo (BSD-3-Clause).

#include "diff_engine.h"
#include "vendor/dtl/dtl.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <new>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

struct LineRef {
  const char *data;
  size_t length;
};

struct LineHash {
  size_t operator()(const LineRef &line) const {
    // FNV-1a hashes bytes only; LineEqual resolves collisions exactly.
    size_t hash = sizeof(size_t) == 8
      ? static_cast<size_t>(1469598103934665603ULL)
      : static_cast<size_t>(2166136261U);
    const size_t prime = sizeof(size_t) == 8
      ? static_cast<size_t>(1099511628211ULL)
      : static_cast<size_t>(16777619U);
    for (size_t i = 0; i < line.length; ++i) {
      hash ^= static_cast<unsigned char>(line.data[i]);
      hash *= prime;
    }
    return hash;
  }
};

struct LineEqual {
  bool operator()(const LineRef &left, const LineRef &right) const {
    return left.length == right.length
      && (left.length == 0 || std::memcmp(left.data, right.data, left.length) == 0);
  }
};

struct Region {
  int alo;
  int ahi;
  int blo;
  int bhi;
};

class HistogramMatcher {
public:
  HistogramMatcher(const AnvilDiffLine *a_lines, int a_count,
                   const AnvilDiffLine *b_lines, int b_count)
    : a_(static_cast<size_t>(a_count) + 1),
      b_(static_cast<size_t>(b_count) + 1),
      anext_(static_cast<size_t>(a_count) + 1),
      bref_(static_cast<size_t>(b_count) + 1),
      acnt_(static_cast<size_t>(a_count) + 1) {
    std::unordered_map<LineRef, int, LineHash, LineEqual> ids;
    ids.reserve(static_cast<size_t>(a_count) + static_cast<size_t>(b_count));
    int next_id = 1;
    for (int i = 1; i <= a_count; ++i) {
      const LineRef line = { a_lines[i - 1].data, a_lines[i - 1].length };
      const auto inserted = ids.emplace(line, next_id);
      if (inserted.second) ++next_id;
      a_[static_cast<size_t>(i)] = inserted.first->second;
    }
    for (int i = 1; i <= b_count; ++i) {
      const LineRef line = { b_lines[i - 1].data, b_lines[i - 1].length };
      const auto inserted = ids.emplace(line, next_id);
      if (inserted.second) ++next_id;
      b_[static_cast<size_t>(i)] = inserted.first->second;
    }

    std::vector<int> first(static_cast<size_t>(next_id) + 1);
    for (int i = a_count; i >= 1; --i) {
      const int id = a_[static_cast<size_t>(i)];
      anext_[static_cast<size_t>(i)] = first[static_cast<size_t>(id)];
      first[static_cast<size_t>(id)] = i;
    }
    for (int i = 1; i <= b_count; ++i) {
      bref_[static_cast<size_t>(i)] = first[static_cast<size_t>(b_[static_cast<size_t>(i)])];
    }

    for (int i = 1; i <= a_count; ++i) {
      if (acnt_[static_cast<size_t>(i)] != 0) continue;
      acnt_[static_cast<size_t>(i)] = 1;
      for (int j = i; anext_[static_cast<size_t>(j)] != 0;) {
        j = anext_[static_cast<size_t>(j)];
        ++acnt_[static_cast<size_t>(i)];
        acnt_[static_cast<size_t>(j)] = -i;
      }
    }
  }

  std::vector<AnvilDiffPair> compare() {
    std::vector<AnvilDiffPair> pairs;
    std::vector<Region> stack;
    if (a_.size() > 1 && b_.size() > 1) {
      stack.push_back({ 1, static_cast<int>(a_.size()), 1, static_cast<int>(b_.size()) });
    }

    while (!stack.empty()) {
      const Region region = stack.back();
      stack.pop_back();
      refill_occurrence_counts(region);

      Region match = {};
      if (find_best_matching_region(region, match)) {
        for (int ai = match.alo, bi = match.blo; ai < match.ahi; ++ai, ++bi) {
          pairs.push_back({ ai, bi });
        }
        // Push the later region first so the earlier region is processed next,
        // matching hdiff/JGit's deterministic traversal.
        if (match.ahi < region.ahi || match.bhi < region.bhi) {
          stack.push_back({ match.ahi, region.ahi, match.bhi, region.bhi });
        }
        if (region.alo < match.alo || region.blo < match.blo) {
          stack.push_back({ region.alo, match.alo, region.blo, match.blo });
        }
      } else if (region_has_common_line(region)) {
        append_shortest_edit_pairs(region, pairs);
      }
    }

    std::sort(pairs.begin(), pairs.end(), [](const AnvilDiffPair &left, const AnvilDiffPair &right) {
      return left.i < right.i || (left.i == right.i && left.j < right.j);
    });
    return pairs;
  }

private:
  static constexpr int kMaxChainLength = 64; // JGit HistogramDiff default.

  int occurrence_count(int a_position) const {
    const int value = acnt_[static_cast<size_t>(a_position)];
    return value >= 0 ? value : acnt_[static_cast<size_t>(-value)];
  }

  bool b_equals_a(int a_position, int b_position) const {
    const int value = acnt_[static_cast<size_t>(a_position)];
    return bref_[static_cast<size_t>(b_position)] == (value >= 0 ? a_position : -value);
  }

  void refill_occurrence_counts(const Region &region) {
    for (int i = region.blo; i < region.bhi; ++i) {
      const int first = bref_[static_cast<size_t>(i)];
      if (first != 0) acnt_[static_cast<size_t>(first)] = 0;
    }
    for (int i = region.alo; i < region.ahi; ++i) {
      const int value = acnt_[static_cast<size_t>(i)];
      if (value < 0) acnt_[static_cast<size_t>(-value)] = 0;
      else acnt_[static_cast<size_t>(i)] = 0;
    }
    for (int i = region.alo; i < region.ahi; ++i) {
      const int value = acnt_[static_cast<size_t>(i)];
      if (value < 0) {
        ++acnt_[static_cast<size_t>(-value)];
      } else if (value == 0) {
        ++acnt_[static_cast<size_t>(i)];
      }
    }
  }

  bool find_best_matching_region(const Region &region, Region &best) const {
    if (region.alo == region.ahi || region.blo == region.bhi) return false;
    int low_count = kMaxChainLength;
    bool found = false;

    for (int i = region.blo; i < region.bhi;) {
      int next_i = i + 1;
      int j = bref_[static_cast<size_t>(i)];
      if (j == 0 || j >= region.ahi || occurrence_count(j) > low_count) {
        i = next_i;
        continue;
      }
      while (j < region.alo && anext_[static_cast<size_t>(j)] != 0) {
        j = anext_[static_cast<size_t>(j)];
      }
      if (j < region.alo || j >= region.ahi) {
        i = next_i;
        continue;
      }

      for (;;) {
        int next_j = anext_[static_cast<size_t>(j)];
        Region candidate = { j, j + 1, i, i + 1 };
        int candidate_low_count = occurrence_count(candidate.alo);
        while (region.alo < candidate.alo && region.blo < candidate.blo
               && b_equals_a(candidate.alo - 1, candidate.blo - 1)) {
          --candidate.alo;
          --candidate.blo;
          candidate_low_count = std::min(candidate_low_count, occurrence_count(candidate.alo));
        }
        while (candidate.ahi < region.ahi && candidate.bhi < region.bhi
               && b_equals_a(candidate.ahi, candidate.bhi)) {
          candidate_low_count = std::min(candidate_low_count, occurrence_count(candidate.ahi));
          ++candidate.ahi;
          ++candidate.bhi;
        }

        if (!found || candidate.ahi - candidate.alo > best.ahi - best.alo
            || candidate_low_count < low_count) {
          best = candidate;
          low_count = candidate_low_count;
          found = true;
        }
        if (next_i < candidate.bhi) next_i = candidate.bhi;
        while (next_j != 0 && next_j < candidate.ahi) {
          next_j = anext_[static_cast<size_t>(next_j)];
        }
        if (next_j == 0 || next_j >= region.ahi) break;
        j = next_j;
      }
      i = next_i;
    }
    return found;
  }

  bool region_has_common_line(const Region &region) const {
    for (int bi = region.blo; bi < region.bhi; ++bi) {
      int ai = bref_[static_cast<size_t>(bi)];
      while (ai != 0 && ai < region.alo) ai = anext_[static_cast<size_t>(ai)];
      if (ai >= region.alo && ai < region.ahi) return true;
    }
    return false;
  }

  void append_shortest_edit_pairs(const Region &region,
                                  std::vector<AnvilDiffPair> &pairs) const {
    if (region.alo == region.ahi || region.blo == region.bhi) return;
    std::vector<int> left(a_.begin() + region.alo, a_.begin() + region.ahi);
    std::vector<int> right(b_.begin() + region.blo, b_.begin() + region.bhi);
    dtl::Diff<int, std::vector<int>> fallback(left, right, true);
    fallback.compose();
    const auto sequence = fallback.getSes().getSequence();
    for (const auto &entry : sequence) {
      if (entry.second.type == dtl::SES_COMMON) {
        pairs.push_back({
          region.alo + static_cast<int>(entry.second.beforeIdx) - 1,
          region.blo + static_cast<int>(entry.second.afterIdx) - 1,
        });
      }
    }
  }

  std::vector<int> a_;
  std::vector<int> b_;
  std::vector<int> anext_;
  std::vector<int> bref_;
  std::vector<int> acnt_;
};

} // namespace

extern "C" AnvilDiffPair *anvil_diff_equal_pairs(
  const AnvilDiffLine *a, int a_count,
  const AnvilDiffLine *b, int b_count,
  int *pair_count
) {
  if (!pair_count) return nullptr;
  *pair_count = -1;
  if (a_count < 0 || b_count < 0 ||
      (a_count > 0 && !a) || (b_count > 0 && !b)) {
    return nullptr;
  }
  for (int i = 0; i < a_count; ++i) {
    if (a[i].length > 0 && !a[i].data) return nullptr;
  }
  for (int i = 0; i < b_count; ++i) {
    if (b[i].length > 0 && !b[i].data) return nullptr;
  }
  try {
    HistogramMatcher matcher(a, a_count, b, b_count);
    const std::vector<AnvilDiffPair> pairs = matcher.compare();
    const size_t allocation_count = std::max<size_t>(1, pairs.size());
    auto *result = static_cast<AnvilDiffPair *>(
      std::malloc(allocation_count * sizeof(AnvilDiffPair))
    );
    if (!result) return nullptr;
    if (!pairs.empty()) {
      std::memcpy(result, pairs.data(), pairs.size() * sizeof(AnvilDiffPair));
    }
    *pair_count = static_cast<int>(pairs.size());
    return result;
  } catch (...) {
    return nullptr;
  }
}

extern "C" void anvil_diff_pairs_free(AnvilDiffPair *pairs) {
  std::free(pairs);
}
