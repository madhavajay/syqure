#pragma once

// Ensure ostream formatter definitions are available when only fmt/format.h is included.
#include_next <fmt/format.h>
#include <fmt/ostream.h>
