require_relative '../app.rb'
require 'bcrypt'

describe "Password hashing with bcrypt" do
  
  describe "hash_password" do
    it "should generate a bcrypt hash" do
      password = "testpassword123"
      hash = hash_password(password)
      
      # bcrypt hashes start with $2 (various versions like $2a$, $2b$, etc.)
      hash.should start_with("$2")
      
      # Should be able to verify the password
      bcrypt_password = BCrypt::Password.new(hash)
      (bcrypt_password == password).should be_true
    end
    
    it "should ignore the salt parameter for backward compatibility" do
      password = "testpassword123"
      hash1 = hash_password(password, "ignored_salt")
      hash2 = hash_password(password)
      
      # Both should be valid bcrypt hashes
      hash1.should start_with("$2")
      hash2.should start_with("$2")
      
      # Should verify the same password
      bcrypt1 = BCrypt::Password.new(hash1)
      bcrypt2 = BCrypt::Password.new(hash2)
      (bcrypt1 == password).should be_true
      (bcrypt2 == password).should be_true
    end
    
    it "should use the configured cost factor" do
      password = "testpassword123"
      hash = hash_password(password)
      
      bcrypt_password = BCrypt::Password.new(hash)
      bcrypt_password.cost.should == BCryptCost
    end
    
    it "should generate different hashes for the same password" do
      password = "testpassword123"
      hash1 = hash_password(password)
      hash2 = hash_password(password)
      
      # Hashes should be different due to random salt
      hash1.should_not == hash2
      
      # But both should verify the same password
      bcrypt1 = BCrypt::Password.new(hash1)
      bcrypt2 = BCrypt::Password.new(hash2)
      (bcrypt1 == password).should be_true
      (bcrypt2 == password).should be_true
    end
  end
  
  describe "check_user_credentials" do
    before do
      # Mock Redis for testing
      @redis_mock = double("redis")
      $r = @redis_mock
    end
    
    it "should authenticate users with bcrypt hashes" do
      username = "testuser"
      password = "testpassword123"
      bcrypt_hash = BCrypt::Password.create(password, cost: 12)
      
      # Mock user data with bcrypt hash
      user_data = {
        'id' => '1',
        'username' => username,
        'password' => bcrypt_hash,
        'auth' => 'auth_token',
        'apisecret' => 'api_secret',
        'salt' => '' # Not used with bcrypt
      }
      
      @redis_mock.should_receive(:get).with("username.to.id:#{username}").and_return('1')
      @redis_mock.should_receive(:hgetall).with("user:1").and_return(user_data)
      
      result = check_user_credentials(username, password)
      result.should == ['auth_token', 'api_secret']
    end
    
    it "should reject users with legacy PBKDF2 hashes" do
      username = "legacyuser"
      password = "testpassword123"
      
      # Mock user data with legacy PBKDF2 hash (hex string, not starting with $2)
      user_data = {
        'id' => '1',
        'username' => username,
        'password' => 'legacy_pbkdf2_hex_hash_here',
        'auth' => 'auth_token',
        'apisecret' => 'api_secret',
        'salt' => 'some_salt'
      }
      
      @redis_mock.should_receive(:get).with("username.to.id:#{username}").and_return('1')
      @redis_mock.should_receive(:hgetall).with("user:1").and_return(user_data)
      
      result = check_user_credentials(username, password)
      result.should be_nil
    end
    
    it "should reject invalid passwords for bcrypt users" do
      username = "testuser"
      correct_password = "testpassword123"
      wrong_password = "wrongpassword"
      bcrypt_hash = BCrypt::Password.create(correct_password, cost: 12)
      
      # Mock user data with bcrypt hash
      user_data = {
        'id' => '1',
        'username' => username,
        'password' => bcrypt_hash,
        'auth' => 'auth_token',
        'apisecret' => 'api_secret',
        'salt' => ''
      }
      
      @redis_mock.should_receive(:get).with("username.to.id:#{username}").and_return('1')
      @redis_mock.should_receive(:hgetall).with("user:1").and_return(user_data)
      
      result = check_user_credentials(username, wrong_password)
      result.should be_nil
    end
    
    it "should return nil for non-existent users" do
      username = "nonexistent"
      password = "anypassword"
      
      @redis_mock.should_receive(:get).with("username.to.id:#{username}").and_return(nil)
      
      result = check_user_credentials(username, password)
      result.should be_nil
    end
  end
end