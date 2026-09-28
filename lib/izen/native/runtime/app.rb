# frozen_string_literal: true

require_relative "runtime/types"
require_relative "runtime/rack_utils"
require_relative "runtime/base64"
require_relative "runtime/secure_random"
require_relative "runtime/crypto"
require_relative "runtime/logger"
require_relative "runtime/bcrypt"
require_relative "runtime/vips"
require_relative "runtime/session_codec"
require_relative "runtime/database"
require_relative "runtime/model"
require_relative "runtime/contract"
require_relative "runtime/repository"
require_relative "runtime/controller"
require_relative "runtime/response"
require_relative "runtime/request"
require_relative "runtime/static_file"
require_relative "runtime/flash"
require_relative "runtime/helpers"
require_relative "runtime/dotenv"
require_relative "runtime/compat"
require_relative "runtime/shims"

# Domain + lowered code (require order emitted by the generator into
# generated/requires.rb).
require_relative "generated/requires"

Dotenv.load

# The application object. Replaces `class App < Izen::Application` and the Roda
# plugins: routing is generated, rendering is generated, session/flash live in
# the runtime.
class App
  SESSION_KEY     = "izen_session"
  SESSION_MAX_AGE = 30 * 24 * 60 * 60

  include Helpers
  include AppHelpers
  include Views
  include Routes

  attr_reader :request, :response

  def initialize
    @current_user_loaded = false
  end

  def session
    @session
  end

  def flash
    @flash
  end

  # Handles one request and returns the Response. On CRuby this is called
  # directly by the test harness; under Spinel it is called by the server.
  def call(request)
    @request         = request
    @response        = Response.new
    request.response = @response
    @session         = SessionCodec.decode(request.cookie(SESSION_KEY))
    @flash           = Flash.new(@session)

    begin
      request.params # parses the body and applies the _method override
      body           = dispatch(request)
      @response.body = body if body
    rescue Halt => halt
      @response.status = halt.status if halt.status
      @response.body   = halt.body if halt.body
    end

    persist_session(request)
    @response
  end

  private

  def persist_session(request)
    if @session.empty?
      if request.cookie(SESSION_KEY)
        @response["Set-Cookie"] = "#{SESSION_KEY}=; path=/; Max-Age=0; HttpOnly; SameSite=Lax"
      end
    else
      value                   = SessionCodec.encode(@session)
      @response["Set-Cookie"] =
        "#{SESSION_KEY}=#{value}; path=/; Max-Age=#{SESSION_MAX_AGE}; HttpOnly; SameSite=Lax"
    end
  end
end
