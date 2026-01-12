#pragma once

// Provide ostream formatter support without relying on system fmt/ostream.h.
#include <fmt/format.h>
#include <sstream>

namespace fmt {
template <typename Char>
struct basic_ostream_formatter {
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

using ostream_formatter = basic_ostream_formatter<char>;

template <typename... T>
void print(std::ostream& os, format_string<T...> fmt, T&&... args) {
  os << format(fmt, std::forward<T>(args)...);
}

template <typename... T>
void print(std::wostream& os,
           basic_format_string<wchar_t, type_identity_t<T>...> fmt,
           T&&... args) {
  os << format(fmt, std::forward<T>(args)...);
}
}  // namespace fmt
