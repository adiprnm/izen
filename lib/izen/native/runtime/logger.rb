# frozen_string_literal: true

# Minimal stand-in for CRuby's stdlib Logger. Spinel has no `logger` package,
# so a source app that does `Logger.new($stdout)` (a very common pattern) needs
# this. Only the surface an app realistically touches is implemented.
class Logger
  DEBUG   = 0
  INFO    = 1
  WARN    = 2
  ERROR   = 3
  FATAL   = 4
  UNKNOWN = 5

  LABELS = {
    DEBUG   => "DEBUG",
    INFO    => "INFO",
    WARN    => "WARN",
    ERROR   => "ERROR",
    FATAL   => "FATAL",
    UNKNOWN => "ANY"
  }.freeze

  def initialize(device = $stdout)
    @device = device
    @level  = DEBUG
  end

  def level
    @level
  end

  def level=(value)
    @level = value
  end

  def debug(message = nil, &block)
    add(DEBUG, message, &block)
  end

  def info(message = nil, &block)
    add(INFO, message, &block)
  end

  def warn(message = nil, &block)
    add(WARN, message, &block)
  end

  def error(message = nil, &block)
    add(ERROR, message, &block)
  end

  def fatal(message = nil, &block)
    add(FATAL, message, &block)
  end

  def unknown(message = nil, &block)
    add(UNKNOWN, message, &block)
  end

  def add(severity, message = nil)
    return true if severity < @level

    message = yield if message.nil? && block_given?
    @device.puts("#{LABELS[severity] || "ANY"}: #{message}")
    true
  end

  def <<(message)
    @device.puts(message.to_s)
    self
  end
end
