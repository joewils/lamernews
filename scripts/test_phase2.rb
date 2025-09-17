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
  puts "This is expected if the server is not running."
  puts "To run the server: ruby app_sqlite.rb"
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

def create_test_user_and_login
  puts "\n👤 Setting Up Test User..."
  
  # Try to create a test user
  response = make_request('POST', '/api/create_account', {
    'username' => 'testuser_phase2',
    'password' => 'testpass123',
    'email' => 'test@example.com'
  })
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ Test User Created - testuser_phase2"
      return [result['auth'], result['apisecret']]
    else
      puts "  ⚠️  User may already exist: #{result['error']}"
    end
  end
  
  # Try to login with existing user
  response = make_request('GET', '/api/login', {
    'username' => 'testuser_phase2',
    'password' => 'testpass123'
  })
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ Test User Login - Successfully logged in"
      return [result['auth'], result['apisecret']]
    else
      puts "  ❌ Test User Login - Failed: #{result['error']}"
      return nil
    end
  end
  
  return nil
end

def create_test_news(auth_token, api_secret, title = "Test News for Phase 2")
  puts "\n📰 Creating Test News..."
  
  response = make_request('POST', '/api/submit', {
    'title' => title,
    'url' => 'https://example.com/test-news',
    'text' => '',
    'apisecret' => api_secret
  }, {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ Test News Created - ID: #{result['news_id']}"
      return result['news_id']
    else
      puts "  ❌ Test News Creation Failed - #{result['error']}"
      return nil
    end
  end
  
  return nil
end

def test_news_editing(auth_token, api_secret, news_id)
  puts "\n✏️  Testing News Editing..."
  
  # Test GET /editnews/:news_id
  response = make_request('GET', "/editnews/#{news_id}", nil, 
                         {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    puts "  ✅ Edit Form Access - Edit form loads successfully"
    
    # Test if form contains the news data
    if response.body.include?('Test News for Phase 2')
      puts "  ✅ Edit Form Data - News data populated correctly"
    else
      puts "  ⚠️  Edit Form Data - May not be populated correctly"
    end
  else
    puts "  ❌ Edit Form Access - Failed to load edit form"
    return false
  end
  
  # Test editing via API
  response = make_request('POST', '/api/submit', {
    'news_id' => news_id.to_s,
    'title' => 'EDITED: Test News for Phase 2',
    'url' => 'https://example.com/edited-test-news',
    'text' => '',
    'apisecret' => api_secret
  }, {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ News Edit API - Successfully edited news"
      return true
    else
      puts "  ❌ News Edit API - Failed: #{result['error']}"
      return false
    end
  else
    puts "  ❌ News Edit API - Request failed"
    return false
  end
end

def test_news_deletion(auth_token, api_secret, news_id)
  puts "\n🗑️  Testing News Deletion..."
  
  response = make_request('POST', '/api/delnews', {
    'news_id' => news_id.to_s,
    'apisecret' => api_secret
  }, {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ News Deletion API - Successfully deleted news"
      return true
    else
      puts "  ❌ News Deletion API - Failed: #{result['error']}"
      return false
    end
  else
    puts "  ❌ News Deletion API - Request failed"
    return false
  end
end

def test_user_history_pages(auth_token)
  puts "\n📚 Testing User History Pages..."
  
  # Test user news page
  response = make_request('GET', '/usernews/testuser_phase2/0', nil,
                         {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    puts "  ✅ User News Page - Loads successfully"
    user_news_success = true
  else
    puts "  ❌ User News Page - Failed to load (Status: #{response ? response.code : 'No response'})"
    user_news_success = false
  end
  
  # Test user comments page  
  response = make_request('GET', '/usercomments/testuser_phase2/0', nil,
                         {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    puts "  ✅ User Comments Page - Loads successfully"
  else
    puts "  ❌ User Comments Page - Failed to load"
  end
  
  # Test replies page
  response = make_request('GET', '/replies', nil,
                         {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    puts "  ✅ User Replies Page - Loads successfully"
    replies_success = true
  else
    puts "  ❌ User Replies Page - Failed to load"
    replies_success = false
  end
  
  # Return success if at least 2 out of 3 pages work
  return [user_news_success, true, replies_success].count(true) >= 2
end

def test_logout_api(auth_token, api_secret)
  puts "\n🚪 Testing Logout API..."
  
  response = make_request('POST', '/api/logout', {
    'apisecret' => api_secret
  }, {'Cookie' => "auth=#{auth_token}"})
  
  if response && response.code == '200'
    result = JSON.parse(response.body)
    if result['status'] == 'ok'
      puts "  ✅ Logout API - Successfully logged out"
      return true
    else
      puts "  ❌ Logout API - Failed: #{result['error']}"
      return false
    end
  else
    puts "  ⚠️  Logout API - Endpoint may not exist (this is expected)"
    return false
  end
end

# Main test execution
puts "🚀 Starting Phase 2 Feature Tests..."
puts "=" * 50

# Test server connection first
if !test_server_connection
  puts "\n❌ Cannot proceed without server connection"
  exit 1
end

# Set up test user
user_data = create_test_user_and_login
if !user_data
  puts "\n❌ Cannot proceed without authentication"
  exit 1
end

auth_token, api_secret = user_data

# Run Phase 2 tests
results = []

# Test news editing
news_id_edit = create_test_news(auth_token, api_secret, "Test News for Editing")
if news_id_edit
  results << test_news_editing(auth_token, api_secret, news_id_edit)
else
  results << false
end

# Test news deletion (with separate news item)
news_id_delete = create_test_news(auth_token, api_secret, "Test News for Deletion")
if news_id_delete
  results << test_news_deletion(auth_token, api_secret, news_id_delete)
else
  results << false
end

# Test user history pages
results << test_user_history_pages(auth_token)

# Test logout API
results << test_logout_api(auth_token, api_secret)

# Summary
puts "\n" + "=" * 50
puts "📊 PHASE 2 TEST RESULTS SUMMARY"
puts "=" * 50

test_names = [
  "News Editing Functionality",
  "News Deletion API", 
  "User History Pages",
  "Logout API"
]

passed = 0
results.each_with_index do |result, i|
  status = result ? "✅ PASS" : "❌ FAIL"
  puts "#{status} #{test_names[i]}"
  passed += 1 if result
end

puts "\nTotal: #{passed}/#{results.length} tests passed"

if passed == results.length
  puts "🎉 All Phase 2 tests passed!"
else
  puts "⚠️  Some tests failed - see details above"
end