# frozen_string_literal: true

RSpec.configure do |config|
  config.before :each, type: :feature do
    OmniAuth.config.mock_auth[:developer] = nil
  end
end
