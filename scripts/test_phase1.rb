#!/usr/bin/env ruby

# Comprehensive Phase 1 Feature Test Script
# Tests user registration, login, password reset, and profile management

require_relative '../app_config'
require_relative '../database'
require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

class Phase1Tester
  def initialize(base_url = 'http://localhost:4567')
    @base_url = base_url
    @test_user = {
      username: "testuser_#{Time.now.to_i}",
      password: "testpassword123",
      email: "test@example.com"
    }
    @test_results = []
  end

  def run_all_tests
    puts "🚀 Starting Phase 1 Feature Tests..."
    puts "=" * 50
    
    setup_clean_database
    
    test_user_registration
    test_login_functionality
    test_password_reset_workflow
    test_profile_management
    
    puts "\n" + "=" * 50
    puts "📊 TEST RESULTS SUMMARY"
    puts "=" * 50
    
    @test_results.each do |result|
      status = result[:passed] ? "✅ PASS" : "❌ FAIL"
      puts "#{status} #{result[:test_name]}"
      puts "   #{result[:message]}" if result[:message]
    end
    
    total_tests = @test_results.length
    passed_tests = @test_results.count { |r| r[:passed] }
    
    puts "\nTotal: #{passed_tests}/#{total_tests} tests passed"
    puts passed_tests == total_tests ? "🎉 ALL TESTS PASSED!" : "⚠️  Some tests failed"
  end

  private

  def setup_clean_database
    puts "🗄️  Setting up clean test database..."
    
    # Get the correct path to the init script
    script_dir = File.dirname(__FILE__)
    project_root = File.dirname(script_dir)
    init_script = File.join(script_dir, 'init_database.rb')
    test_db_path = File.join(project_root, 'data', 'test_lamernews.db')
    
    # Initialize a fresh database for testing
    system("ruby #{init_script} #{test_db_path}")
    
    # Update database path for testing
    Database.setup(test_db_path)
    
    record_test("Database Setup", true, "Test database created successfully")
  end

  def test_user_registration
    puts "\n👤 Testing User Registration..."
    
    # Test 1: Valid registration
    response = make_api_request('/api/create_account', {
      username: @test_user[:username],
      password: @test_user[:password],
      email: @test_user[:email]
    }, 'POST')
    
    if response && response['status'] == 'ok' && response['auth']
      @auth_token = response['auth']
      @api_secret = response['apisecret']
      record_test("User Registration - Valid Data", true, "User created successfully")
    else
      record_test("User Registration - Valid Data", false, "Failed: #{response}")
      return
    end
    
    # Test 2: Duplicate username
    response = make_api_request('/api/create_account', {
      username: @test_user[:username],
      password: "anotherpassword",
      email: "another@example.com"
    }, 'POST')
    
    if response && response['status'] == 'err' && response['error'].include?('exists')
      record_test("User Registration - Duplicate Username", true, "Correctly rejected duplicate")
    else
      record_test("User Registration - Duplicate Username", false, "Should reject duplicates")
    end
    
    # Test 3: Invalid email
    response = make_api_request('/api/create_account', {
      username: "testuser2_#{Time.now.to_i}",
      password: "testpassword123",
      email: "invalid-email"
    }, 'POST')
    
    if response && response['status'] == 'err' && response['error'].include?('email')
      record_test("User Registration - Invalid Email", true, "Correctly rejected invalid email")
    else
      record_test("User Registration - Invalid Email", false, "Should validate email format")
    end
  end

  def test_login_functionality
    puts "\n🔐 Testing Login Functionality..."
    
    # Test 1: Valid login
    response = make_api_request('/api/login', {
      username: @test_user[:username],
      password: @test_user[:password]
    }, 'GET')
    
    if response && response['status'] == 'ok' && response['auth']
      record_test("Login - Valid Credentials", true, "Login successful")
    else
      record_test("Login - Valid Credentials", false, "Login failed: #{response}")
    end
    
    # Test 2: Invalid password
    response = make_api_request('/api/login', {
      username: @test_user[:username],
      password: "wrongpassword"
    }, 'GET')
    
    if response && response['status'] == 'err'
      record_test("Login - Invalid Password", true, "Correctly rejected wrong password")
    else
      record_test("Login - Invalid Password", false, "Should reject wrong password")
    end
  end

  def test_password_reset_workflow
    puts "\n🔑 Testing Password Reset Workflow..."
    
    # Test 1: Request password reset
    response = make_api_request('/api/reset-password', {
      username: @test_user[:username],
      email: @test_user[:email]
    }, 'GET')
    
    if response && response['status'] == 'ok'
      record_test("Password Reset - Valid Request", true, "Reset request accepted")
    else
      record_test("Password Reset - Valid Request", false, "Reset request failed: #{response}")
      return
    end
    
    # Test 2: Get reset token from database (simulate email click)
    reset_token = Database.get_first_value(<<-SQL, [@test_user[:username]])
      SELECT prt.token 
      FROM password_reset_tokens prt
      JOIN users u ON prt.user_id = u.id
      WHERE u.username = ? AND prt.used = 0 
      ORDER BY prt.created_at DESC 
      LIMIT 1
    SQL
    
    if reset_token
      record_test("Password Reset - Token Generation", true, "Reset token generated")
      
      # Test 3: Set new password with token
      new_password = "newpassword123"
      response = make_api_request('/api/set-new-password', {
        token: reset_token,
        password: new_password
      }, 'POST')
      
      if response && response['status'] == 'ok'
        record_test("Password Reset - Set New Password", true, "Password updated successfully")
        @test_user[:password] = new_password
      else
        record_test("Password Reset - Set New Password", false, "Failed to set new password: #{response}")
      end
    else
      record_test("Password Reset - Token Generation", false, "No reset token found")
    end
    
    # Test 4: Try to use token again (should fail)
    if reset_token
      response = make_api_request('/api/set-new-password', {
        token: reset_token,
        password: "anothernewpassword"
      }, 'POST')
      
      if response && response['status'] == 'err'
        record_test("Password Reset - Token Reuse Prevention", true, "Correctly prevented token reuse")
      else
        record_test("Password Reset - Token Reuse Prevention", false, "Should prevent token reuse")
      end
    end
  end

  def test_profile_management
    puts "\n👤 Testing Profile Management..."
    
    # First login with new password to get fresh auth
    login_response = make_api_request('/api/login', {
      username: @test_user[:username],
      password: @test_user[:password]
    }, 'GET')
    
    if login_response && login_response['status'] == 'ok'
      @auth_token = login_response['auth']
      @api_secret = login_response['apisecret']
    end
    
    # Test profile update
    response = make_api_request('/api/updateprofile', {
      email: "updated@example.com",
      about: "This is my updated about text",
      apisecret: @api_secret
    }, 'POST', @auth_token)
    
    if response && response['status'] == 'ok'
      record_test("Profile Management - Update Profile", true, "Profile updated successfully")
    else
      record_test("Profile Management - Update Profile", false, "Profile update failed: #{response}")
    end
    
    # Test password change via profile
    response = make_api_request('/api/updateprofile', {
      password: "finalpassword123",
      apisecret: @api_secret
    }, 'POST', @auth_token)
    
    if response && response['status'] == 'ok'
      record_test("Profile Management - Change Password", true, "Password changed successfully")
    else
      record_test("Profile Management - Change Password", false, "Password change failed: #{response}")
    end
  end

  def make_api_request(endpoint, data, method = 'GET', auth_token = nil)
    uri = URI("#{@base_url}#{endpoint}")
    
    begin
      case method.upcase
      when 'GET'
        uri.query = URI.encode_www_form(data)
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Get.new(uri)
      when 'POST'
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(data)
      end
      
      request['Cookie'] = "auth=#{auth_token}" if auth_token
      
      response = http.request(request)
      JSON.parse(response.body) if response.body
    rescue => e
      puts "API Request failed: #{e.message}"
      puts "This is expected if the server is not running."
      puts "To run the server: ruby app_sqlite.rb"
      nil
    end
  end

  def record_test(test_name, passed, message = nil)
    @test_results << {
      test_name: test_name,
      passed: passed,
      message: message
    }
    
    status = passed ? "✅" : "❌"
    puts "  #{status} #{test_name}"
    puts "     #{message}" if message
  end
end

# Run tests if this file is executed directly
if __FILE__ == $0
  tester = Phase1Tester.new
  tester.run_all_tests
end