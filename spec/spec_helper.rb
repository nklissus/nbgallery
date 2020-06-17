RSpec.configure do |config|
  if Bullet.enable?
    config.before(:each) { Bullet.start_request }
    config.after(:each)  { Bullet.end_request }
  end
end
