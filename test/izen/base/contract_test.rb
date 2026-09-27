# frozen_string_literal: true

require_relative "../../test_helper"

class ContractTest < Minitest::Test
  class SignupContract < Izen::Base::Contract
    params do
      required :name,  String, min: 1, max: 120
      optional :email, String
      optional :age,   Integer, default: 0
    end

    rule :email do
      error(:email, "wajib diisi") if values[:name] == "admin" && values[:email].to_s.empty?
    end
  end

  def test_success_coerces_and_applies_defaults
    result = SignupContract.new.call("name" => "Adi", "age" => "30")

    assert result.success?
    assert_equal "Adi", result[:name]
    assert_equal 30, result[:age]
  end

  def test_reports_missing_required
    result = SignupContract.new.call({})

    assert result.failure?
    assert_includes result.errors[:name], "wajib diisi"
  end

  def test_min_length
    result = SignupContract.new.call(name: "")

    assert result.failure?
  end

  def test_custom_rule
    result = SignupContract.new.call(name: "admin")

    assert result.failure?
    assert_includes result.errors[:email], "wajib diisi"
  end
end
