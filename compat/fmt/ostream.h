#pragma once

// Load the system fmt ostream header, then add a compatibility fallback.
#include_next <fmt/ostream.h>
#include <sstream>

#ifndef FMT_VERSION
#define FMT_VERSION 0
#endif

#if FMT_VERSION < 90000
namespace fmt {
template <typename Char = char>
struct ostream_formatter {
  template <typename ParseContext>
  constexpr auto parse(ParseContext& ctx) { return ctx.begin(); }

  template <typename T, typename FormatContext>
  auto format(const T& value, FormatContext& ctx) const {
    std::basic_ostringstream<Char> os;
    os << value;
    auto str = os.str();
    return formatter<basic_string_view<Char>, Char>{}.format(
        basic_string_view<Char>(str.data(), str.size()), ctx);
  }
};
}  // namespace fmt
#endif
