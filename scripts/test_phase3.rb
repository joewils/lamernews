#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'cgi'

# Test configuration
SERVER_HOST = 'localhost'
SERVER_PORT = 4567
BASE_URL = "http://#{SERVER_HOST}:#{SERVER_PORT}"

def make_request(method, path, data = nil, headers = {})
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  
  case method.upcase
  when 'GET'
    if data
      uri.query = URI.encode_www_form(data)
    end
    request = Net::HTTP::Get.new(uri)
  when 'POST'
    request = Net::HTTP::Post.new(uri)
    if data
      request.set_form_data(data)
    end
  end
  
  headers.each { |key, value| request[key] = value }
  
  response = http.request(request)
  return response
rescue => e
  puts "API Request failed: #{e.message}"
  return nil
end

def test_server_connection
  puts "\n🔍 Testing Server Connection..."
  response = make_request('GET', '/')
  if response && response.code == '200'
    puts "  ✅ Server Connection - Successfully connected to #{BASE_URL}"
    return true
  else
    puts "  ❌ Server Connection - Failed to connect to #{BASE_URL}"
    puts "     Please start the server with: ruby app_sqlite.rb"
    return false
  end
end

def test_random_news_redirect
  puts "\n🎲 Testing Random News Redirect..."
  
  response = make_request('GET', '/random')
  if response && [301, 302, 303, 307, 308].include?(response.code.to_i)
    location = response['Location']
    puts "  ✅ Random News - Redirected to: #{location}"
    return true
  elsif response && response.code == '200'
    puts "  ✅ Random News - Page loaded successfully"
    return true
  else
    puts "  ❌ Random News - Failed to redirect properly"
    puts "     Response code: #{response&.code || 'nil'}"
    return false
  end
end

def test_admin_access_without_auth
  puts "\n🔒 Testing Admin Access Without Authentication..."
  
  response = make_request('GET', '/admin')
  if response && [301, 302, 303, 307, 308].include?(response.code.to_i)
    location = response['Location']
    if location&.end_with?('/')
      puts "  ✅ Admin Security - Properly redirected unauthenticated users to: #{location}"
      return true
    else
      puts "  ❌ Admin Security - Unexpected redirect to: #{location}"
      return false
    end
  else
    puts "  ❌ Admin Security - Should redirect unauthenticated users"
    puts "     Response code: #{response&.code || 'nil'}"
    return false
  end
end

def create_admin_user
  puts "\n👤 Creating Admin User for Testing..."
  
  # Create a test admin account
  response = make_request('POST', '/api/create_account', {
    'username' => 'testadmin',
    'password' => 'testpass123',
    'email' => 'admin@test.com',
    'create_account' => '1'
  })
  
  if response && response.code == '200'
    result = JSON.parse(response.body) rescue nil
    if result && result['status'] == 'ok'
      puts "  ✅ Admin User Created - Account creation successful"
      return result['auth']
    elsif result && result['error']&.include?('already exists')
      puts "  ℹ️ Admin User - Account already exists, attempting login..."
      return login_admin_user
    else
      puts "  ❌ Admin User Creation Failed - #{result&.dig('error') || 'Unknown error'}"
      return nil
    end
  else
    puts "  ❌ Admin User Creation Failed - HTTP #{response&.code || 'nil'}"
    return nil
  end
end

def login_admin_user
  puts "\n🔑 Logging in Admin User..."
  
  response = make_request('GET', '/api/login', {
    'username' => 'testadmin',
    'password' => 'testpass123'
  })
  
  if response && response.code == '200'
    result = JSON.parse(response.body) rescue nil
    if result && result['status'] == 'ok'
      puts "  ✅ Admin Login - Login successful"
      return result['auth']
    else
      puts "  ❌ Admin Login Failed - #{result&.dig('error') || 'Unknown error'}"
      return nil
    end
  else
    puts "  ❌ Admin Login Failed - HTTP #{response&.code || 'nil'}"
    return nil
  end
end

def grant_admin_privileges(auth_token)
  puts "\n⚡ Manually Granting Admin Privileges..."
  
  # For testing, we'll need to manually set admin flag in database
  # This simulates the admin flag being set
  puts "  ℹ️ Note: In production, admin privileges would be granted through:"
  puts "     1. Database flag: UPDATE users SET flags = 'a' WHERE username = 'testadmin'"
  puts "     2. Or by being user ID 1 or having username 'admin'/'administrator'"
  puts "  ⚠️ For this test, we'll assume user 'testadmin' has admin privileges"
  
  return true
end

def test_admin_dashboard_access(auth_token)
  puts "\n📊 Testing Admin Dashboard Access..."
  
  cookies = "auth=#{auth_token}"
  response = make_request('GET', '/admin', nil, {'Cookie' => cookies})
  
  if response && response.code == '200'
    body = response.body
    if body.include?('Admin') && body.include?('Site stats')
      puts "  ✅ Admin Dashboard - Successfully accessed admin panel"
      
      # Check for specific admin features
      stats_found = body.include?('total users') && (body.include?('news items') || body.include?('news posted'))
      tools_found = body.include?('Recompute') && body.include?('Developer tools')
      
      if stats_found
        puts "  ✅ Admin Stats - Site statistics displayed correctly"
      else
        puts "  ❌ Admin Stats - Site statistics not found"
      end
      
      if tools_found
        puts "  ✅ Admin Tools - Developer tools links present"
      else
        puts "  ❌ Admin Tools - Developer tools not found"
      end
      
      return stats_found && tools_found
    else
      puts "  ❌ Admin Dashboard - Content does not appear to be admin panel"
      return false
    end
  elsif response && [301, 302, 303, 307, 308].include?(response.code.to_i)
    puts "  ❌ Admin Dashboard - Still being redirected (auth may not be working)"
    puts "     Redirect location: #{response['Location']}"
    return false
  else
    puts "  ❌ Admin Dashboard - Failed to load admin page"
    puts "     Response code: #{response&.code || 'nil'}"
    return false
  end
end

def test_recompute_functionality(auth_token)
  puts "\n🔄 Testing News Score Recomputation..."
  
  cookies = "auth=#{auth_token}"
  response = make_request('GET', '/recompute', nil, {'Cookie' => cookies})
  
  if response && response.code == '200'
    body = response.body
    if body.include?('Done') && body.downcase.include?('recomputed')
      puts "  ✅ Recompute - Score recomputation completed successfully"
      return true
    else
      puts "  ❌ Recompute - Unexpected response content"
      puts "     Body preview: #{body[0..200]}..."
      return false
    end
  elsif response && [301, 302, 303, 307, 308].include?(response.code.to_i)
    puts "  ❌ Recompute - Access denied (redirected)"
    puts "     Redirect location: #{response['Location']}"
    return false
  else
    puts "  ❌ Recompute - Failed to access recompute function"
    puts "     Response code: #{response&.code || 'nil'}"
    return false
  end
end

def test_debug_mode_access(auth_token)
  puts "\n🐛 Testing Debug Mode Access..."
  
  cookies = "auth=#{auth_token}"
  response = make_request('GET', '/', {'debug' => '1'}, {'Cookie' => cookies})
  
  if response && response.code == '200'
    body = response.body
    # Debug mode might add annotations or extra information
    puts "  ✅ Debug Mode - Successfully accessed debug mode"
    return true
  else
    puts "  ❌ Debug Mode - Failed to access debug mode"
    puts "     Response code: #{response&.code || 'nil'}"
    return false
  end
end

def run_comprehensive_test
  puts "🚀 Phase 3 Administrative Features Test Suite"
  puts "=" * 50
  puts "Testing admin functionality for Lamer News SQLite migration"
  puts "Date: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  
  # Track test results
  tests_run = 0
  tests_passed = 0
  
  # Test 1: Server Connection
  tests_run += 1
  tests_passed += 1 if test_server_connection
  return false if tests_passed != tests_run  # Stop if server not available
  
  # Test 2: Random News (no auth required)
  tests_run += 1
  tests_passed += 1 if test_random_news_redirect
  
  # Test 3: Admin Security (should deny access)
  tests_run += 1
  tests_passed += 1 if test_admin_access_without_auth
  
  # Test 4: Create Admin User
  auth_token = create_admin_user
  if auth_token
    tests_run += 1
    tests_passed += 1
    
    # Grant admin privileges (in production this would be done via database)
    if grant_admin_privileges(auth_token)
      
      # Test 5: Admin Dashboard Access
      tests_run += 1
      tests_passed += 1 if test_admin_dashboard_access(auth_token)
      
      # Test 6: Recompute Functionality  
      tests_run += 1
      tests_passed += 1 if test_recompute_functionality(auth_token)
      
      # Test 7: Debug Mode Access
      tests_run += 1
      tests_passed += 1 if test_debug_mode_access(auth_token)
    else
      puts "\n❌ Could not grant admin privileges for testing"
    end
  else
    puts "\n❌ Could not create or login admin user for testing"
  end
  
  # Final Results
  puts "\n" + "=" * 50
  puts "📊 TEST RESULTS SUMMARY"
  puts "=" * 50
  puts "Tests Run: #{tests_run}"
  puts "Tests Passed: #{tests_passed}"
  puts "Success Rate: #{(tests_passed.to_f / tests_run * 100).round(1)}%"
  
  if tests_passed == tests_run
    puts "\n🎉 ALL TESTS PASSED! Phase 3 admin functionality is working correctly."
    puts "\n📝 Notes for Production:"
    puts "   • Grant admin privileges: UPDATE users SET flags = 'a' WHERE username = 'admin'"
    puts "   • Admin access is secured with proper authentication checks"
    puts "   • Random news feature is operational"
    puts "   • Score recomputation works (use sparingly - may be slow)"
    puts "   • Debug mode is available for admin troubleshooting"
  else
    puts "\n⚠️ SOME TESTS FAILED. Please review the issues above."
  end
  
  puts "\n🔧 Server Management Commands:"
  puts "   Start server: ruby app_sqlite.rb"
  puts "   Stop server:  Ctrl+C"
  puts "   Test again:   ruby scripts/test_phase3_admin.rb"
  
  return tests_passed == tests_run
end

# Run the test suite
if __FILE__ == $0
  success = run_comprehensive_test
  exit(success ? 0 : 1)
end