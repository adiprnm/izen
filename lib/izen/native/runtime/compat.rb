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
