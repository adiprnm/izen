# frozen_string_literal: true

# Roda-like flash hash, persisted in the signed session.
#
#   flash["notice"] = "saved"   # visible on the NEXT request
#   flash.now["error"] = "no"   # visible on THIS request
#   flash["notice"]             # reads what the previous request left
class Flash
  class Now
    def initialize(hash)
      @hash = hash
    end

    def [](key)
      @hash[key.to_s]
    end

    def []=(key, value)
      @hash[key.to_s] = value
    end
  end

  def initialize(session)
    @session = session
    @current = @session["flash"].is_a?(Hash) ? @session["flash"] : {}
    @session.delete("flash")
  end

  def [](key)
    @current[key.to_s]
  end

  def []=(key, value)
    @session["flash"]         ||= {}
    @session["flash"][key.to_s] = value
  end

  def now
    @now ||= Now.new(@current)
  end
end
