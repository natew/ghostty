#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace std {
inline namespace __1 {

[[noreturn]] void __libcpp_verbose_abort(char const* format, ...) {
  va_list args;
  va_start(args, format);
  std::vfprintf(stderr, format, args);
  va_end(args);
  std::abort();
}

}  // namespace __1
}  // namespace std
