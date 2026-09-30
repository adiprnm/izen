# frozen_string_literal: true

# Compatibility layer for the generated runtime.
#
# The source app is written against the full `Izen::` namespace (the Izen
# convention), while the lowered runtime defines the base classes at the top
# level / under `Base`. These aliases let the copied domain code keep its
# original constant paths.

module Izen
  Base     = ::Base
  Database = ::Database

  # The source app reads static assets relative to Izen.root (icons). Under the
  # native build the process runs from the app directory, so default to "."
  # (override with APP_ROOT when the binary is started elsewhere).
  def self.root
    ENV["APP_ROOT"] || "."
  end
end

# Erubi stand-in. When the app renders with `escape: true` the generator passes
# `escapefunc: "h"`, so this is only reached by `<%== %>` templates compiled
# with the default settings.
module Erubi
  module_function

  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end
end
